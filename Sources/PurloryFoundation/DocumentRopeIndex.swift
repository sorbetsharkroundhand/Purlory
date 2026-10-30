import Foundation

/// Typed projections supply their own summaries; tree edits have one implementation.
/// Copies must retain the record identity and must never mutate an issued snapshot.
package protocol DocumentRopeNode: AnyObject {
    var left: Self? { get }
    var right: Self? { get }
    var count: Int { get }
    var priority: UInt64 { get }
    func copy(left: Self?, right: Self?) -> Self
}

package enum DocumentRopeIndex<Node: DocumentRopeNode> {
    package static func split(_ node: Node?, count: Int, visits: inout Int) -> (Node?, Node?) {
        guard let node else { return (nil, nil) }
        visits += 1
        let leftCount = node.left?.count ?? 0
        if count <= leftCount {
            let (before, after) = split(node.left, count: count, visits: &visits)
            return (before, node.copy(left: after, right: node.right))
        }
        let (before, after) = split(node.right, count: count - leftCount - 1, visits: &visits)
        return (node.copy(left: node.left, right: before), after)
    }

    package static func merge(_ left: Node?, _ right: Node?, visits: inout Int) -> Node? {
        guard let left else { return right }
        guard let right else { return left }
        visits += 1
        if left.priority < right.priority {
            return left.copy(left: left.left, right: merge(left.right, right, visits: &visits))
        }
        return right.copy(left: merge(left, right.left, visits: &visits), right: right.right)
    }

    package static func nextPriority(_ state: inout UInt64) -> UInt64 {
        state ^= state << 13; state ^= state >> 7; state ^= state << 17
        return state
    }
}
