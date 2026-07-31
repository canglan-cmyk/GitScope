import Foundation

/// One occurrence of a searched identifier in the repository working tree.
public struct SymbolReference: Sendable {
    public let filePath: String   // repo-relative
    public let lineNumber: Int    // 1-based
    public let lineText: String
    /// Whether this file is part of the current diff (set by the caller's
    /// annotation pass; references outside the diff are potential missed
    /// call sites — the interesting ones).
    public var isInDiff: Bool = false

    public init(filePath: String, lineNumber: Int, lineText: String, isInDiff: Bool = false) {
        self.filePath = filePath
        self.lineNumber = lineNumber
        self.lineText = lineText
        self.isInDiff = isInDiff
    }
}

/// Finds identifier references across the repository using `git grep`
/// (fast, respects .gitignore, tracked files only).
public struct ReferenceFinder: Sendable {

    private let gitPath: String

    public init(gitPath: String = "/usr/bin/git") {
        self.gitPath = gitPath
    }

    /// Searches the working tree for a word-bounded identifier.
    /// Returns matches capped at `limit` to keep the UI responsive.
    public func findReferences(
        to identifier: String,
        in repository: URL,
        limit: Int = 500
    ) async throws -> [SymbolReference] {
        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count < 200 else { return [] }

        // -n: line numbers, -w: word boundary, -I: skip binaries,
        // --untracked: include new files not yet committed.
        let output = try await run(
            arguments: [
                "grep", "-n", "-w", "-I", "--untracked",
                "--fixed-strings", "-e", trimmed, "--", ".",
            ],
            in: repository
        )

        var references: [SymbolReference] = []
        references.reserveCapacity(min(output.count, limit))

        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: true) {
            guard references.count < limit else { break }
            // Format: path:line:content  (content may itself contain colons).
            let parts = rawLine.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3, let lineNumber = Int(parts[1]) else { continue }
            references.append(SymbolReference(
                filePath: String(parts[0]),
                lineNumber: lineNumber,
                lineText: String(parts[2]).trimmingCharacters(in: .whitespaces)
            ))
        }
        return references
    }

    /// Annotates references with whether their file appears in `diffPaths`.
    public func annotate(
        _ references: [SymbolReference],
        diffPaths: Set<String>
    ) -> [SymbolReference] {
        references.map { reference in
            var annotated = reference
            annotated.isInDiff = diffPaths.contains(reference.filePath)
            return annotated
        }
    }

    // MARK: Process plumbing

    private func run(arguments: [String], in directory: URL) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: gitPath)
            process.arguments = arguments
            process.currentDirectoryURL = directory

            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
                return
            }

            // Read fully before waiting to avoid pipe-buffer deadlock.
            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            _ = stderr.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            // git grep exits 1 when nothing matches — that's not an error.
            guard process.terminationStatus == 0 || process.terminationStatus == 1 else {
                continuation.resume(throwing: GitEngineError.commandFailed(
                    command: "git " + arguments.joined(separator: " "),
                    exitCode: process.terminationStatus,
                    stderr: ""
                ))
                return
            }
            continuation.resume(returning: String(data: data, encoding: .utf8) ?? "")
        }
    }
}
