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
/// printed declarations: a large macOS allow list runs to thousands of lines.
nonisolated enum TextDiff {
    /// Above this many cells (changed old lines × changed new lines), the
    /// changed middle is shown as removed, then added, instead of building a
    /// table that would take hundreds of megabytes.
    static let tableLimit = 4_000_000

    static func lines(from old: String, to new: String) -> [DiffLine] {
        let a = old.isEmpty ? [] : old.components(separatedBy: "\n")
        let b = new.isEmpty ? [] : new.components(separatedBy: "\n")
        var result: [DiffLine] = []
        func append(_ kind: DiffLine.Kind, _ text: String) {
            result.append(DiffLine(kind: kind, text: text, index: result.count))
        }

        // Lines shared at the start and the end need no table: an edit usually
        // touches a few lines in the middle.
        var prefix = 0
        while prefix < a.count && prefix < b.count && a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < a.count - prefix && suffix < b.count - prefix && a[a.count - 1 - suffix] == b[b.count - 1 - suffix] {
            suffix += 1
        }
        for line in a[..<prefix] { append(.unchanged, line) }
        let oldMiddle = Array(a[prefix..<(a.count - suffix)])
        let newMiddle = Array(b[prefix..<(b.count - suffix)])

        if oldMiddle.count * newMiddle.count > tableLimit {
            for line in oldMiddle { append(.removed, line) }
            for line in newMiddle { append(.added, line) }
        } else {
            // lengths[i][j] = LCS length of oldMiddle[i...] and newMiddle[j...]
            var lengths = Array(repeating: Array(repeating: 0, count: newMiddle.count + 1), count: oldMiddle.count + 1)
            for i in stride(from: oldMiddle.count - 1, through: 0, by: -1) {
                for j in stride(from: newMiddle.count - 1, through: 0, by: -1) {
                    lengths[i][j] = oldMiddle[i] == newMiddle[j]
                        ? lengths[i + 1][j + 1] + 1
                        : max(lengths[i + 1][j], lengths[i][j + 1])
                }
            }
            var i = 0, j = 0
            while i < oldMiddle.count && j < newMiddle.count {
                if oldMiddle[i] == newMiddle[j] {
                    append(.unchanged, oldMiddle[i]); i += 1; j += 1
                } else if lengths[i + 1][j] >= lengths[i][j + 1] {
                    append(.removed, oldMiddle[i]); i += 1
                } else {
                    append(.added, newMiddle[j]); j += 1
                }
            }
            while i < oldMiddle.count { append(.removed, oldMiddle[i]); i += 1 }
            while j < newMiddle.count { append(.added, newMiddle[j]); j += 1 }
        }

        for line in a[(a.count - suffix)...] { append(.unchanged, line) }
        return result
    }
}
