import Foundation

/// One line of a unified line diff.
nonisolated struct DiffLine: Hashable, Sendable, Identifiable {
    enum Kind: Hashable, Sendable { case unchanged, removed, added }
    let kind: Kind
    let text: String
    /// Position in the diff, for stable identity.
    let index: Int

    var id: Int { index }
}

/// A line diff based on the longest common subsequence. Inputs here are pretty
/// printed declarations, a few hundred lines at most.
nonisolated enum TextDiff {
    static func lines(from old: String, to new: String) -> [DiffLine] {
        let a = old.isEmpty ? [] : old.components(separatedBy: "\n")
        let b = new.isEmpty ? [] : new.components(separatedBy: "\n")
        // lengths[i][j] = LCS length of a[i...] and b[j...]
        var lengths = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                lengths[i][j] = a[i] == b[j] ? lengths[i + 1][j + 1] + 1 : max(lengths[i + 1][j], lengths[i][j + 1])
            }
        }
        var result: [DiffLine] = []
        var i = 0, j = 0
        func append(_ kind: DiffLine.Kind, _ text: String) {
            result.append(DiffLine(kind: kind, text: text, index: result.count))
        }
        while i < a.count && j < b.count {
            if a[i] == b[j] {
                append(.unchanged, a[i]); i += 1; j += 1
            } else if lengths[i + 1][j] >= lengths[i][j + 1] {
                append(.removed, a[i]); i += 1
            } else {
                append(.added, b[j]); j += 1
            }
        }
        while i < a.count { append(.removed, a[i]); i += 1 }
        while j < b.count { append(.added, b[j]); j += 1 }
        return result
    }
}
