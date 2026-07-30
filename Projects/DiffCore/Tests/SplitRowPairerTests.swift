import Testing
@testable import DiffCore

@Suite("SplitRowPairer")
struct SplitRowPairerTests {

    private func makeHunk(_ changes: [LineChange]) -> DiffHunk {
        var oldNumber = 1
        var newNumber = 1
        let lines = changes.enumerated().map { index, change -> DiffLine in
            switch change {
            case .context:
                defer { oldNumber += 1; newNumber += 1 }
                return DiffLine(
                    change: .context, oldLineNumber: oldNumber,
                    newLineNumber: newNumber, content: "ctx\(index)"
                )
            case .deletion:
                defer { oldNumber += 1 }
                return DiffLine(
                    change: .deletion, oldLineNumber: oldNumber,
                    newLineNumber: nil, content: "del\(index)"
                )
            case .addition:
                defer { newNumber += 1 }
                return DiffLine(
                    change: .addition, oldLineNumber: nil,
                    newLineNumber: newNumber, content: "add\(index)"
                )
            }
        }
        return DiffHunk(
            oldStart: 1, oldCount: oldNumber - 1,
            newStart: 1, newCount: newNumber - 1,
            sectionHeading: "", lines: lines
        )
    }

    @Test("Context lines occupy both sides")
    func contextBothSides() {
        let pairs = SplitRowPairer.pairs(for: makeHunk([.context, .context]))
        #expect(pairs == [
            SplitRowPair(oldLineIndex: 0, newLineIndex: 0),
            SplitRowPair(oldLineIndex: 1, newLineIndex: 1),
        ])
    }

    @Test("Deletion+addition runs pair index-wise as modifications")
    func modifiedPairs() {
        // del del add add → (d0,a2) (d1,a3)
        let pairs = SplitRowPairer.pairs(for: makeHunk([.deletion, .deletion, .addition, .addition]))
        #expect(pairs == [
            SplitRowPair(oldLineIndex: 0, newLineIndex: 2),
            SplitRowPair(oldLineIndex: 1, newLineIndex: 3),
        ])
    }

    @Test("Unbalanced runs leave placeholders")
    func unbalancedRuns() {
        // del add add → (d0,a1) (nil,a2)
        let pairs = SplitRowPairer.pairs(for: makeHunk([.deletion, .addition, .addition]))
        #expect(pairs == [
            SplitRowPair(oldLineIndex: 0, newLineIndex: 1),
            SplitRowPair(oldLineIndex: nil, newLineIndex: 2),
        ])
    }

    @Test("Pure additions sit right-side only")
    func pureAdditions() {
        let pairs = SplitRowPairer.pairs(for: makeHunk([.context, .addition, .context]))
        #expect(pairs == [
            SplitRowPair(oldLineIndex: 0, newLineIndex: 0),
            SplitRowPair(oldLineIndex: nil, newLineIndex: 1),
            SplitRowPair(oldLineIndex: 2, newLineIndex: 2),
        ])
    }

    @Test("Pure deletions sit left-side only")
    func pureDeletions() {
        let pairs = SplitRowPairer.pairs(for: makeHunk([.context, .deletion, .context]))
        #expect(pairs == [
            SplitRowPair(oldLineIndex: 0, newLineIndex: 0),
            SplitRowPair(oldLineIndex: 1, newLineIndex: nil),
            SplitRowPair(oldLineIndex: 2, newLineIndex: 2),
        ])
    }

    @Test("Deletion run split by context does not pair with later additions")
    func contextBreaksPairing() {
        // del ctx add → del pairs alone, add pairs alone
        let pairs = SplitRowPairer.pairs(for: makeHunk([.deletion, .context, .addition]))
        #expect(pairs == [
            SplitRowPair(oldLineIndex: 0, newLineIndex: nil),
            SplitRowPair(oldLineIndex: 1, newLineIndex: 1),
            SplitRowPair(oldLineIndex: nil, newLineIndex: 2),
        ])
    }
}
