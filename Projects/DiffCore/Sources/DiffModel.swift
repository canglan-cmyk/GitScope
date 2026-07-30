import Foundation

// MARK: - Line

/// The change classification of a single diff line.
public enum LineChange: Sendable, Hashable {
    case context
    case addition
    case deletion
}

/// One line inside a hunk.
///
/// `oldLineNumber` / `newLineNumber` are 1-based line numbers in the old/new
/// file respectively. A deletion has no `newLineNumber`; an addition has no
/// `oldLineNumber`.
public struct DiffLine: Sendable, Hashable {
    public let change: LineChange
    public let oldLineNumber: Int?
    public let newLineNumber: Int?
    /// Line content without the leading `+`/`-`/` ` marker, without the
    /// trailing newline.
    public let content: String
    /// True when the source ended without a trailing newline
    /// (`\ No newline at end of file`).
    public var hasNoTrailingNewline: Bool

    /// Range of characters (in `content`) that differ from the paired
    /// line, populated by intra-line highlighting. `nil` until computed.
    public var intralineHighlight: Range<Int>?

    public init(
        change: LineChange,
        oldLineNumber: Int?,
        newLineNumber: Int?,
        content: String,
        hasNoTrailingNewline: Bool = false,
        intralineHighlight: Range<Int>? = nil
    ) {
        self.change = change
        self.oldLineNumber = oldLineNumber
        self.newLineNumber = newLineNumber
        self.content = content
        self.hasNoTrailingNewline = hasNoTrailingNewline
        self.intralineHighlight = intralineHighlight
    }
}

// MARK: - Hunk

/// A contiguous change region, i.e. one `@@ -a,b +c,d @@` section.
public struct DiffHunk: Sendable, Hashable {
    public let oldStart: Int
    public let oldCount: Int
    public let newStart: Int
    public let newCount: Int
    /// Optional section heading following the second `@@` (function context).
    public let sectionHeading: String
    public var lines: [DiffLine]

    public init(
        oldStart: Int,
        oldCount: Int,
        newStart: Int,
        newCount: Int,
        sectionHeading: String = "",
        lines: [DiffLine] = []
    ) {
        self.oldStart = oldStart
        self.oldCount = oldCount
        self.newStart = newStart
        self.newCount = newCount
        self.sectionHeading = sectionHeading
        self.lines = lines
    }

    /// Canonical `@@ -a,b +c,d @@` header text.
    public var headerText: String {
        var text = "@@ -\(oldStart),\(oldCount) +\(newStart),\(newCount) @@"
        if !sectionHeading.isEmpty {
            text += " \(sectionHeading)"
        }
        return text
    }
}

// MARK: - File

/// The kind of change applied to a file.
public enum FileChange: Sendable, Hashable {
    case added
    case deleted
    case modified
    case renamed
    case copied
    case typeChanged
}

/// The diff of one file.
public struct FileDiff: Sendable, Hashable {
    public let change: FileChange
    public let oldPath: String?
    public let newPath: String?
    public var hunks: [DiffHunk]
    public let isBinary: Bool

    public init(
        change: FileChange,
        oldPath: String?,
        newPath: String?,
        hunks: [DiffHunk] = [],
        isBinary: Bool = false
    ) {
        self.change = change
        self.oldPath = oldPath
        self.newPath = newPath
        self.hunks = hunks
        self.isBinary = isBinary
    }

    /// The single path that best identifies this file (new path when
    /// available, otherwise old path).
    public var canonicalPath: String { newPath ?? oldPath ?? "" }

    public var additionCount: Int {
        hunks.reduce(0) { $0 + $1.lines.count(where: { $0.change == .addition }) }
    }

    public var deletionCount: Int {
        hunks.reduce(0) { $0 + $1.lines.count(where: { $0.change == .deletion }) }
    }
}

// MARK: - Document

/// A complete diff, possibly spanning multiple files.
public struct DiffDocument: Sendable, Hashable {
    public var files: [FileDiff]

    public init(files: [FileDiff] = []) {
        self.files = files
    }

    public var totalAdditions: Int { files.reduce(0) { $0 + $1.additionCount } }
    public var totalDeletions: Int { files.reduce(0) { $0 + $1.deletionCount } }
}
