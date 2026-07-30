import Foundation

/// Parses unified diff text (as produced by `git diff`, GitHub's
/// `application/vnd.github.diff` media type, or `git format-patch` bodies)
/// into `DiffDocument` values.
///
/// The parser is intentionally forgiving: unknown extended header lines are
/// skipped, and a diff that starts directly with `@@` (single-file patch
/// without `diff --git`) is accepted.
public struct UnifiedDiffParser: Sendable {

    public enum ParseError: Error, Equatable {
        case malformedHunkHeader(line: String)
    }

    public init() {}

    // MARK: - Public API

    public func parse(_ text: String) throws -> DiffDocument {
        var files: [FileDiff] = []
        var builder = FileBuilder()

        // Substring-based split avoids copying each line's storage.
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)[...]
        // A trailing newline yields one empty trailing element; drop it.
        if let last = lines.last, last.isEmpty {
            lines = lines.dropLast()
        }

        for rawLine in lines {
            if rawLine.hasPrefix("diff --git ") {
                if let file = builder.finish() { files.append(file) }
                builder = FileBuilder()
                builder.beginFile(gitHeaderLine: rawLine)
            } else if rawLine.hasPrefix("@@") {
                try builder.beginHunk(headerLine: rawLine)
            } else if builder.isInsideHunk {
                builder.consumeHunkLine(rawLine)
            } else {
                builder.consumeHeaderLine(rawLine)
            }
        }
        if let file = builder.finish() { files.append(file) }

        return DiffDocument(files: files)
    }

    // MARK: - File builder

    private struct FileBuilder {
        private var started = false
        private var oldPath: String?
        private var newPath: String?
        private var explicitChange: FileChange?
        private var isBinary = false
        private var hunks: [DiffHunk] = []
        private var currentHunk: DiffHunk?
        private var oldCursor = 0
        private var newCursor = 0

        var isInsideHunk: Bool { currentHunk != nil }

        mutating func beginFile(gitHeaderLine: Substring) {
            started = true
            // `diff --git a/path b/path` — used only as a fallback source of
            // paths; `---`/`+++`/rename headers take precedence.
            let payload = gitHeaderLine.dropFirst("diff --git ".count)
            let components = Self.splitGitPaths(payload)
            if let components {
                oldPath = components.0
                newPath = components.1
            }
        }

        mutating func consumeHeaderLine(_ line: Substring) {
            guard started || line.hasPrefix("---") || line.hasPrefix("+++") else {
                // Preamble noise before the first file (e.g. commit message).
                return
            }
            started = true

            if line.hasPrefix("--- ") {
                oldPath = Self.stripPathPrefix(line.dropFirst(4))
                if oldPath == nil { explicitChange = .added }  // "/dev/null"
            } else if line.hasPrefix("+++ ") {
                newPath = Self.stripPathPrefix(line.dropFirst(4))
                if newPath == nil { explicitChange = .deleted }  // "/dev/null"
            } else if line.hasPrefix("rename from ") {
                explicitChange = .renamed
                oldPath = String(line.dropFirst("rename from ".count))
            } else if line.hasPrefix("rename to ") {
                explicitChange = .renamed
                newPath = String(line.dropFirst("rename to ".count))
            } else if line.hasPrefix("copy from ") {
                explicitChange = .copied
                oldPath = String(line.dropFirst("copy from ".count))
            } else if line.hasPrefix("copy to ") {
                explicitChange = .copied
                newPath = String(line.dropFirst("copy to ".count))
            } else if line.hasPrefix("new file mode") {
                explicitChange = .added
            } else if line.hasPrefix("deleted file mode") {
                explicitChange = .deleted
            } else if line.hasPrefix("old mode") || line.hasPrefix("new mode") {
                explicitChange = .typeChanged
            } else if line.hasPrefix("Binary files ") || line.hasPrefix("GIT binary patch") {
                isBinary = true
            }
            // index/mode/similarity lines are intentionally ignored.
        }

        mutating func beginHunk(headerLine: Substring) throws {
            closeCurrentHunk()
            started = true

            guard let header = Self.parseHunkHeader(headerLine) else {
                throw ParseError.malformedHunkHeader(line: String(headerLine))
            }
            currentHunk = DiffHunk(
                oldStart: header.oldStart,
                oldCount: header.oldCount,
                newStart: header.newStart,
                newCount: header.newCount,
                sectionHeading: header.sectionHeading
            )
            oldCursor = header.oldStart
            newCursor = header.newStart
        }

        mutating func consumeHunkLine(_ line: Substring) {
            guard currentHunk != nil else { return }

            if line.hasPrefix("\\") {
                // "\ No newline at end of file" applies to the previous line.
                if let lastIndex = currentHunk?.lines.indices.last {
                    currentHunk?.lines[lastIndex].hasNoTrailingNewline = true
                }
                return
            }

            let marker = line.first
            let content = String(line.dropFirst())
            switch marker {
            case "+":
                currentHunk?.lines.append(DiffLine(
                    change: .addition,
                    oldLineNumber: nil,
                    newLineNumber: newCursor,
                    content: content
                ))
                newCursor += 1
            case "-":
                currentHunk?.lines.append(DiffLine(
                    change: .deletion,
                    oldLineNumber: oldCursor,
                    newLineNumber: nil,
                    content: content
                ))
                oldCursor += 1
            case " ":
                currentHunk?.lines.append(DiffLine(
                    change: .context,
                    oldLineNumber: oldCursor,
                    newLineNumber: newCursor,
                    content: content
                ))
                oldCursor += 1
                newCursor += 1
            case nil:
                // Fully empty line inside a hunk: an empty context line whose
                // leading space was stripped by transport.
                currentHunk?.lines.append(DiffLine(
                    change: .context,
                    oldLineNumber: oldCursor,
                    newLineNumber: newCursor,
                    content: ""
                ))
                oldCursor += 1
                newCursor += 1
            default:
                // Unknown marker: treat as end of the hunk region.
                closeCurrentHunk()
            }
        }

        mutating func finish() -> FileDiff? {
            closeCurrentHunk()
            guard started, oldPath != nil || newPath != nil else { return nil }

            let change: FileChange
            if let explicitChange {
                change = explicitChange
            } else if oldPath == nil {
                change = .added
            } else if newPath == nil {
                change = .deleted
            } else {
                change = .modified
            }
            return FileDiff(
                change: change,
                oldPath: oldPath,
                newPath: newPath,
                hunks: hunks,
                isBinary: isBinary
            )
        }

        private mutating func closeCurrentHunk() {
            if let hunk = currentHunk {
                hunks.append(hunk)
                currentHunk = nil
            }
        }

        // MARK: Header helpers

        /// Parses `@@ -a[,b] +c[,d] @@[ heading]`.
        static func parseHunkHeader(
            _ line: Substring
        ) -> (oldStart: Int, oldCount: Int, newStart: Int, newCount: Int, sectionHeading: String)? {
            guard line.hasPrefix("@@ ") else { return nil }
            let afterPrefix = line.dropFirst(3)
            guard let closingRange = afterPrefix.range(of: " @@") else { return nil }

            let rangesPart = afterPrefix[..<closingRange.lowerBound]
            let heading = afterPrefix[closingRange.upperBound...]
                .trimmingCharacters(in: .whitespaces)

            let parts = rangesPart.split(separator: " ")
            guard parts.count == 2,
                  parts[0].hasPrefix("-"), parts[1].hasPrefix("+"),
                  let old = parseRange(parts[0].dropFirst()),
                  let new = parseRange(parts[1].dropFirst())
            else { return nil }

            return (old.start, old.count, new.start, new.count, heading)
        }

        /// Parses `start[,count]`; count defaults to 1.
        private static func parseRange(_ text: Substring) -> (start: Int, count: Int)? {
            if let comma = text.firstIndex(of: ",") {
                guard let start = Int(text[..<comma]),
                      let count = Int(text[text.index(after: comma)...])
                else { return nil }
                return (start, count)
            }
            guard let start = Int(text) else { return nil }
            return (start, 1)
        }

        /// Strips the `a/` or `b/` prefix; returns nil for `/dev/null`.
        static func stripPathPrefix(_ text: Substring) -> String? {
            // Some tools append a tab + timestamp after the path.
            let path = text.split(separator: "\t", maxSplits: 1)[0]
            if path == "/dev/null" { return nil }
            if path.hasPrefix("a/") || path.hasPrefix("b/") {
                return String(path.dropFirst(2))
            }
            return String(path)
        }

        /// Splits the `a/old b/new` payload of a `diff --git` line.
        ///
        /// Paths containing spaces are ambiguous in this header; we use the
        /// common-case heuristic of splitting at ` b/`. Quoted paths are
        /// passed through minus the quotes.
        static func splitGitPaths(_ payload: Substring) -> (String?, String?)? {
            guard let separator = payload.range(of: " b/") else {
                return nil
            }
            var old = payload[..<separator.lowerBound]
            var new = payload[separator.upperBound...]
            if old.hasPrefix("a/") { old = old.dropFirst(2) }
            if old.hasPrefix("\"") { old = old.dropFirst().dropLast() }
            if new.hasPrefix("\"") { new = new.dropFirst().dropLast() }
            return (String(old), String(new))
        }
    }
}
