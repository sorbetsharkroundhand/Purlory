import Foundation

/// Explicit writer-owned registrations; lookup never creates an entity.
public struct StoryNamedEntity: Equatable, Sendable {
    public let id: UUID
    public let name: String
    public let aliases: [String]
    public init(id: UUID, name: String, aliases: [String] = []) {
        self.id = id; self.name = name; self.aliases = aliases
    }
}

public struct StoryEntityResolver: Sendable {
    private let characters, objects, rules: [String: Set<UUID>]
    private let characterIDs, objectIDs, ruleIDs: Set<UUID>
    public init(characters: [CharacterCard], objects: [StoryNamedEntity] = [], rules: [StoryNamedEntity] = []) {
        self.characters = Self.index(characters.map {
            .init(id: $0.id, name: $0.name, aliases: $0.aliases.components(separatedBy: ","))
        })
        self.objects = Self.index(objects); self.rules = Self.index(rules)
        characterIDs = Set(characters.map(\.id)); objectIDs = Set(objects.map(\.id)); ruleIDs = Set(rules.map(\.id))
    }
    public func character(named: String) -> UUID? { Self.unique(named, in: characters) }
    public func object(named: String) -> UUID? { Self.unique(named, in: objects) }
    public func rule(named: String) -> UUID? { Self.unique(named, in: rules) }

    package func accepts(_ content: StoryFact.Content) -> Bool {
        switch content {
        case .event(_, let participants): participants.allSatisfy { characterIDs.contains($0) }
        case .characterState(let value): characterIDs.contains(value.characterID)
        case .characterAge(let value): characterIDs.contains(value.characterID)
        case .characterKnowledge(let value): characterIDs.contains(value.characterID)
        case .relationship(let value): characterIDs.contains(value.fromID) && characterIDs.contains(value.toID)
        case .objectState(let value): objectIDs.contains(value.objectID)
        case .worldRule(let value): ruleIDs.contains(value.ruleID)
        }
    }
    private static func index(_ registrations: [StoryNamedEntity]) -> [String: Set<UUID>] {
        var result: [String: Set<UUID>] = [:]
        for entity in registrations {
            for raw in [entity.name] + entity.aliases {
                let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty { result[name, default: []].insert(entity.id) }
            }
        }
        return result
    }
    private static func unique(_ raw: String, in index: [String: Set<UUID>]) -> UUID? {
        guard let ids = index[raw.trimmingCharacters(in: .whitespacesAndNewlines)], ids.count == 1 else { return nil }
        return ids.first
    }
}
