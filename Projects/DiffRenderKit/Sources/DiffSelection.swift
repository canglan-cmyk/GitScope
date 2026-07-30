import AppKit
import CoreText
import DiffCore

// MARK: - Selection model

/// A text position inside the flattened diff table: row index plus a UTF-16
/// character offset within that row's text content.
public struct DiffTextPosition: Comparable, Sendable, Equatable {
    public var row: Int
    public var offset: Int

    public init(row: Int, offset: Int) {
        self.row = row
        self.offset = offset
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.row, lhs.offset) < (rhs.row, rhs.offset)
    }
}

/// An inclusive-start, exclusive-end text selection over table rows.
/// Living in the model layer (not in cells) means the selection survives
/// row recycling in the virtualized table.
public struct DiffSelection: Sendable, Equatable {
    public var anchor: DiffTextPosition
    public var focus: DiffTextPosition

    public init(anchor: DiffTextPosition, focus: DiffTextPosition) {
        self.anchor = anchor
        self.focus = focus
    }

    public var start: DiffTextPosition { min(anchor, focus) }
    public var end: DiffTextPosition { max(anchor, focus) }
    public var isEmpty: Bool { anchor == focus }

    /// The selected character range within a given row, or nil if the row is
    /// outside the selection. `rowTextLength` is the row's full text length.
    public func range(inRow row: Int, textLength: Int) -> Range<Int>? {
        guard !isEmpty, row >= start.row, row <= end.row else { return nil }
        let lower = row == start.row ? min(start.offset, textLength) : 0
        let upper = row == end.row ? min(end.offset, textLength) : textLength
        guard upper >= lower else { return nil }
        return lower..<upper
    }
}
