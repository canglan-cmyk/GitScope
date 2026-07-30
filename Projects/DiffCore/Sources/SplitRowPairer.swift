import Foundation

/// One aligned row in a side-by-side (split) diff: an optional old-side line
/// and an optional new-side line.
///
/// Pairing semantics (matching GitUp/Kaleidoscope conventions):
/// - context lines occupy both sides,
/// - a run of deletions followed by a run of additions is paired index-wise
///   (deletion i sits beside addition i), representing "modified" lines,
/// - unpaired deletions/additions get an empty placeholder on the other side.
public struct SplitRowPair: Sendable, Equatable {
    /// Index into `hunk.lines` for the old (left) side, if any.
    public var oldLineIndex: Int?
    /// Index into `hunk.lines` for the new (right) side, if any.
    public var newLineIndex: Int?

    public init(oldLineIndex: Int?, newLineIndex: Int?) {
        self.oldLineIndex = oldLineIndex
        self.newLineIndex = newLineIndex
    }
}

/// Pairs the lines of a hunk into side-by-side rows.
public enum SplitRowPairer {

    public static func pairs(for hunk: DiffHunk) -> [SplitRowPair] {
        var result: [SplitRowPair] = []
        result.reserveCapacity(hunk.lines.count)

        var index = 0
        let lines = hunk.lines

        while index < lines.count {
            switch lines[index].change {
            case .context:
                result.append(SplitRowPair(oldLineIndex: index, newLineIndex: index))
                index += 1

            case .deletion:
                // Collect the run of deletions...
                var deletions: [Int] = []
                while index < lines.count, lines[index].change == .deletion {
                    deletions.append(index)
                    index += 1
                }
                // ...and the immediately following run of additions.
                var additions: [Int] = []
                while index < lines.count, lines[index].change == .addition {
                    additions.append(index)
                    index += 1
                }
                // Pair them index-wise; leftovers get placeholders.
                let paired = max(deletions.count, additions.count)
                for i in 0..<paired {
                    result.append(SplitRowPair(
                        oldLineIndex: i < deletions.count ? deletions[i] : nil,
                        newLineIndex: i < additions.count ? additions[i] : nil
                    ))
                }

            case .addition:
                // Additions with no preceding deletions: right side only.
                result.append(SplitRowPair(oldLineIndex: nil, newLineIndex: index))
                index += 1
            }
        }

        return result
    }
}
