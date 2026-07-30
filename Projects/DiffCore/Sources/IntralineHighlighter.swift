import Foundation

/// Computes intra-line highlight ranges for paired deleted/added lines using
/// common prefix/suffix trimming.
///
/// This is an O(n), zero-allocation approach: characters shared at the start
/// and at the end of both lines are excluded, and whatever remains in the
/// middle of each line is the highlighted (changed) region. For the dominant
/// "small edit within a line" case this matches user expectation while being
/// far cheaper than a character-level Myers diff.
public enum IntralineHighlighter {

    /// Returns highlight ranges expressed as `Character` offsets into each
    /// line's content, or `nil` ranges when the lines are identical.
    public static func highlightRanges(
        deleted: String,
        added: String
    ) -> (deleted: Range<Int>?, added: Range<Int>?) {
        let deletedChars = Array(deleted)
        let addedChars = Array(added)

        var prefix = 0
        while prefix < deletedChars.count,
              prefix < addedChars.count,
              deletedChars[prefix] == addedChars[prefix] {
            prefix += 1
        }

        var suffix = 0
        while suffix < deletedChars.count - prefix,
              suffix < addedChars.count - prefix,
              deletedChars[deletedChars.count - 1 - suffix] == addedChars[addedChars.count - 1 - suffix] {
            suffix += 1
        }

        let deletedRange = prefix..<(deletedChars.count - suffix)
        let addedRange = prefix..<(addedChars.count - suffix)

        return (
            deletedRange.isEmpty ? nil : deletedRange,
            addedRange.isEmpty ? nil : addedRange
        )
    }

    /// Applies intra-line highlighting to all pairable deletion/addition runs
    /// in a hunk, mirroring the pairing rule used by mature diff renderers:
    /// a run of N deletions immediately followed by a run of N additions is
    /// paired index-by-index; runs of unequal length are left unhighlighted
    /// to avoid misleading pairings.
    public static func annotate(hunk: inout DiffHunk) {
        var deletionStart: Int?
        var additionStart: Int?

        func flush(at endIndex: Int) {
            guard let dStart = deletionStart, let aStart = additionStart else {
                deletionStart = nil
                additionStart = nil
                return
            }
            let deletionCount = aStart - dStart
            let additionCount = endIndex - aStart
            if deletionCount == additionCount {
                for offset in 0..<deletionCount {
                    let dIndex = dStart + offset
                    let aIndex = aStart + offset
                    let ranges = highlightRanges(
                        deleted: hunk.lines[dIndex].content,
                        added: hunk.lines[aIndex].content
                    )
                    hunk.lines[dIndex].intralineHighlight = ranges.deleted
                    hunk.lines[aIndex].intralineHighlight = ranges.added
                }
            }
            deletionStart = nil
            additionStart = nil
        }

        for index in hunk.lines.indices {
            switch hunk.lines[index].change {
            case .deletion:
                if additionStart != nil {
                    flush(at: index)
                }
                if deletionStart == nil { deletionStart = index }
            case .addition:
                if additionStart == nil { additionStart = index }
            case .context:
                flush(at: index)
            }
        }
        flush(at: hunk.lines.count)
    }

    /// Convenience: annotates every hunk of a file diff.
    public static func annotate(file: inout FileDiff) {
        for index in file.hunks.indices {
            annotate(hunk: &file.hunks[index])
        }
    }
}
