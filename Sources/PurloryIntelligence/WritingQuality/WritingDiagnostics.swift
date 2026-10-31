import Foundation

public enum WritingDiagnosticCategory: String, Codable, CaseIterable, Sendable {
    case correctness
    case style
    case vocabulary
}

public enum WritingDiagnosticKind: String, Codable, CaseIterable, Sendable {
    case spelling
    case spacing
    case grammar

    case repeatedWord
    case repeatedParticle
    case repeatedEnding
    case repeatedConnector
    case redundantConnector
    case connectiveChain
    case repeatedSentenceStart
    case sentenceLength
    case sentenceRhythm
    case cadenceVariation
    case characterVoice

    case vagueWord
    case overusedWord
    case wordAlternative
}

public enum WritingDiagnosticSeverity: String, Codable, CaseIterable, Sendable {
    /// Informational pattern; normally Review-only.
    case info
    /// Non-blocking writing suggestion; normally Living Margin / Review.
    case suggestion
    /// High-confidence correctness issue eligible for a subtle inline mark.
    case correctness
}

/// UTF-16 range used by NSTextView/NSRange without leaking AppKit into the core model.
public struct WritingDiagnosticRange: Codable, Hashable, Sendable {
    public var location: Int
    public var length: Int

    public init(location: Int, length: Int) {
        self.location = location
        self.length = length
    }

    public init(_ range: NSRange) {
        self.init(location: range.location, length: range.length)
    }

    public var nsRange: NSRange {
        NSRange(location: location, length: length)
    }
}

public struct WritingDiagnostic: Identifiable, Codable, Hashable, Sendable {
    /// Stable rule/provider-owned identity for this occurrence.
    public var id: String
    public var ruleID: String
    public var providerID: String
    public var category: WritingDiagnosticCategory
    public var kind: WritingDiagnosticKind
    public var severity: WritingDiagnosticSeverity
    public var range: WritingDiagnosticRange
    /// Other occurrences that explain a repetition/relationship.
    public var relatedRanges: [WritingDiagnosticRange]
    public var message: String
    public var reason: String?
    public var confidence: Double?
    public var alternatives: [String]
    /// BCP-47 style language tag such as "ko", "en", "ja".
    public var languageTag: String

    public init(
        id: String,
        ruleID: String,
        providerID: String,
        category: WritingDiagnosticCategory,
        kind: WritingDiagnosticKind,
        severity: WritingDiagnosticSeverity,
        range: WritingDiagnosticRange,
        relatedRanges: [WritingDiagnosticRange] = [],
        message: String,
        reason: String? = nil,
        confidence: Double? = nil,
        alternatives: [String] = [],
        languageTag: String
    ) {
        self.id = id
        self.ruleID = ruleID
        self.providerID = providerID
        self.category = category
        self.kind = kind
        self.severity = severity
        self.range = range
        self.relatedRanges = relatedRanges
        self.message = message
        self.reason = reason
        self.confidence = confidence
        self.alternatives = alternatives
        self.languageTag = languageTag
    }
}

public enum WritingQualitySensitivity: String, Codable, CaseIterable, Sendable {
    case off
    case low
    case standard
    case high
}

/// Durable proofreading preferences. This is intentionally separate from User Canon.
public struct WritingStyleProfile: Codable, Equatable, Sendable {
    public var ignoredRuleIDs: Set<String>
    public var learnedWords: Set<String>
    public var repetitionSensitivity: WritingQualitySensitivity
    public var dialogueSensitivity: WritingQualitySensitivity

    public init(
        ignoredRuleIDs: Set<String> = [],
        learnedWords: Set<String> = [],
        repetitionSensitivity: WritingQualitySensitivity = .standard,
        dialogueSensitivity: WritingQualitySensitivity = .standard
    ) {
        self.ignoredRuleIDs = ignoredRuleIDs
        self.learnedWords = learnedWords
        self.repetitionSensitivity = repetitionSensitivity
        self.dialogueSensitivity = dialogueSensitivity
    }

    private enum CodingKeys: String, CodingKey {
        case ignoredRuleIDs, learnedWords, repetitionSensitivity, dialogueSensitivity
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        ignoredRuleIDs = values.contains(.ignoredRuleIDs) ? try values.decode(Set<String>.self, forKey: .ignoredRuleIDs) : []
        learnedWords = values.contains(.learnedWords) ? try values.decode(Set<String>.self, forKey: .learnedWords) : []
        repetitionSensitivity = values.contains(.repetitionSensitivity) ? try values.decode(WritingQualitySensitivity.self, forKey: .repetitionSensitivity) : .standard
        dialogueSensitivity = values.contains(.dialogueSensitivity) ? try values.decode(WritingQualitySensitivity.self, forKey: .dialogueSensitivity) : .standard
    }
}

public enum WritingDiagnosticsScope: String, Codable, Sendable {
    /// Dirty sentence/paragraph window used during normal editing.
    case local
    /// Explicit full-document analysis used by Review/background work.
    case document
}

/// Declared speaker names, independent of any Fiction storage schema.
public struct WritingVoiceSubject: Equatable, Sendable {
    public let id: UUID
    public let name: String
    public let aliases: [String]
    public init(id: UUID, name: String, aliases: [String] = []) { self.id = id; self.name = name; self.aliases = aliases }
}

public struct WritingDiagnosticsRequest: Sendable {
    public var projectID: WritingProjectID
    public var documentID: WritingDocumentID
    public var text: String
    public var languageTag: String
    public var scope: WritingDiagnosticsScope
    public var dirtyRange: WritingDiagnosticRange?
    public var voiceSubjects: [WritingVoiceSubject] = []
    public var styleProfile: WritingStyleProfile

    public init(
        projectID: WritingProjectID,
        documentID: WritingDocumentID,
        text: String,
        languageTag: String,
        scope: WritingDiagnosticsScope = .local,
        dirtyRange: WritingDiagnosticRange? = nil,
        styleProfile: WritingStyleProfile = WritingStyleProfile()
    ) {
        self.projectID = projectID
        self.documentID = documentID
        self.text = text
        self.languageTag = languageTag
        self.scope = scope
        self.dirtyRange = dirtyRange
        self.styleProfile = styleProfile
    }
}

/// Language/NLP libraries live behind this boundary. Core diagnostics never expose Kiwi
/// or any other provider-specific token/POS type.
public protocol WritingDiagnosticsProvider: Sendable {
    var id: String { get }
    func analyze(_ request: WritingDiagnosticsRequest) async throws -> [WritingDiagnostic]
}

public struct WritingDiagnosticsSnapshot: Sendable {
    public var generation: UInt64
    public var projectID: WritingProjectID
    public var documentID: WritingDocumentID
    public var diagnostics: [WritingDiagnostic]
    public var providerOutcomes: [WritingProviderOutcome]

    public init(
        generation: UInt64,
        projectID: WritingProjectID,
        documentID: WritingDocumentID,
        diagnostics: [WritingDiagnostic],
        providerOutcomes: [WritingProviderOutcome] = []
    ) {
        self.providerOutcomes = providerOutcomes
        self.generation = generation
        self.projectID = projectID
        self.documentID = documentID
        self.diagnostics = diagnostics
    }
}

/// Cancellable, generation-scoped provider coordinator.
///
/// This actor does not know about NSTextView, Fiction, disk storage, or MLX. A newer edit
/// cancels the previous analysis; even an uncooperative provider cannot publish a stale
/// snapshot because generation ownership is checked after the awaited work completes.
public actor WritingDiagnosticsEngine {
    private let providers: [any WritingDiagnosticsProvider]
    package nonisolated let configurationRevision: String
    private var generation: UInt64 = 0
    private var activeTask: Task<WritingDiagnosticsSnapshot?, Never>?

    public init(providers: [any WritingDiagnosticsProvider]) {
        self.providers = providers
        configurationRevision = providers.map(\.id).sorted().joined(separator: "|")
    }

    public func analyze(_ request: WritingDiagnosticsRequest) async
        -> WritingDiagnosticsSnapshot?
    {
        guard !Task.isCancelled else { return nil }
        generation &+= 1
        let ownedGeneration = generation
        activeTask?.cancel()
        let providers = self.providers
        let task = Task<WritingDiagnosticsSnapshot?, Never> {
            let results = await withTaskGroup(of: WritingProviderResult.self, returning: [WritingProviderResult].self) { group in
                for provider in providers {
                    group.addTask {
                        do {
                            try Task.checkCancellation()
                            let raw = try await provider.analyze(request)
                            try Task.checkCancellation()
                            let validated = Self.normalized(raw, request: request)
                            return .init(diagnostics: validated.diagnostics,
                                outcome: .init(providerID: provider.id, status: validated.invalid ? .failed : .success,
                                               reason: validated.invalid ? .provider : nil))
                        } catch {
                            let outcome = (provider as? any WritingDiagnosticsFailureClassifying)?.failureOutcome(error)
                                ?? .init(providerID: provider.id, status: .failed, reason: .provider)
                            return .init(diagnostics: [], outcome: outcome)
                        }
                    }
                }
                var result: [WritingProviderResult] = []
                for await value in group {
                    if Task.isCancelled { group.cancelAll(); return [] }
                    result.append(value)
                }
                return result
            }
            guard !Task.isCancelled else { return nil }
            var seen = Set<String>()
            let diagnostics = results.flatMap(\.diagnostics).filter { seen.insert($0.id).inserted }.sorted {
                if $0.range.location != $1.range.location { return $0.range.location < $1.range.location }
                if $0.range.length != $1.range.length { return $0.range.length < $1.range.length }
                return $0.id < $1.id
            }
            return WritingDiagnosticsSnapshot(generation: ownedGeneration, projectID: request.projectID, documentID: request.documentID,
                diagnostics: diagnostics, providerOutcomes: results.map(\.outcome).sorted { $0.providerID < $1.providerID })
        }

        activeTask = task
        let snapshot = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }

        guard generation == ownedGeneration else { return nil }
        activeTask = nil
        return snapshot
    }

    public func cancel() {
        generation &+= 1
        activeTask?.cancel()
        activeTask = nil
    }

    nonisolated private static func normalized(_ diagnostics: [WritingDiagnostic], request: WritingDiagnosticsRequest)
        -> (diagnostics: [WritingDiagnostic], invalid: Bool) {
        let source = request.text as NSString
        func valid(_ range: WritingDiagnosticRange) -> Bool {
            guard range.location >= 0, range.location < source.length, range.length > 0,
                  range.length <= source.length - range.location else { return false }
            return source.rangeOfComposedCharacterSequences(for: range.nsRange) == range.nsRange
        }
        var result: [WritingDiagnostic] = [], invalid = false
        for finding in diagnostics {
            guard valid(finding.range), finding.relatedRanges.allSatisfy(valid) else { invalid = true; continue }
            if !request.styleProfile.ignoredRuleIDs.contains(finding.ruleID) { result.append(finding) }
        }
        return (result, invalid)
    }
}

private struct WritingProviderResult: Sendable {
    package let diagnostics: [WritingDiagnostic]
    package let outcome: WritingProviderOutcome
}
