import Foundation
import DiffCore

/// `GitEngine` implementation that shells out to the system `git` binary.
///
/// This is the reference channel: simplest to implement, always agrees with
/// what the user sees on the command line, and serves as the correctness
/// baseline for the future libgit2 (SwiftGitX) in-process channel.
public struct GitCLIEngine: GitEngine {

    /// Path of the git executable. `/usr/bin/git` is the Xcode shim present
    /// on every macOS installation.
    private let gitPath: String

    public init(gitPath: String = "/usr/bin/git") {
        self.gitPath = gitPath
    }

    // MARK: - GitEngine

    public func repositoryRoot(at url: URL) async throws -> URL {
        do {
            let output = try await run(
                ["rev-parse", "--show-toplevel"],
                workingDirectory: url
            )
            let path = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return URL(fileURLWithPath: path, isDirectory: true)
        } catch let error as GitEngineError {
            if case .commandFailed = error {
                throw GitEngineError.notARepository(path: url.path)
            }
            throw error
        }
    }

    public func refs(in repository: URL) async throws -> [GitRef] {
        let output = try await run(
            [
                "for-each-ref",
                "--format=%(refname)\t%(refname:short)",
                "refs/heads", "refs/remotes", "refs/tags",
            ],
            workingDirectory: repository
        )

        var refs: [GitRef] = []
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let fullName = String(parts[0])
            let shortName = String(parts[1])

            let kind: GitRef.Kind
            if fullName.hasPrefix("refs/heads/") {
                kind = .localBranch
            } else if fullName.hasPrefix("refs/remotes/") {
                // Skip symbolic HEAD entries like `origin/HEAD`.
                if shortName.hasSuffix("/HEAD") { continue }
                kind = .remoteBranch
            } else if fullName.hasPrefix("refs/tags/") {
                kind = .tag
            } else {
                kind = .revision
            }
            refs.append(GitRef(name: shortName, kind: kind, fullName: fullName))
        }
        return refs
    }

    public func currentBranch(in repository: URL) async throws -> GitRef? {
        let output = try await run(
            ["branch", "--show-current"],
            workingDirectory: repository
        )
        let name = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }  // Detached HEAD.
        return GitRef(name: name, kind: .localBranch, fullName: "refs/heads/\(name)")
    }

    public func diff(
        in repository: URL,
        base: String,
        head: String,
        mode: ComparisonMode
    ) async throws -> DiffDocument {
        let range: String
        switch mode {
        case .twoDot: range = "\(base)..\(head)"
        case .threeDot: range = "\(base)...\(head)"
        }

        let output = try await run(
            [
                "diff",
                "--no-color",
                "--no-ext-diff",
                "--find-renames",
                range,
            ],
            workingDirectory: repository
        )

        var document = try UnifiedDiffParser().parse(output)
        for index in document.files.indices {
            IntralineHighlighter.annotate(file: &document.files[index])
        }
        return document
    }

    // MARK: - Process runner

    /// Runs git with the given arguments and returns stdout as UTF-8 text.
    private func run(
        _ arguments: [String],
        workingDirectory: URL
    ) async throws -> String {
        guard FileManager.default.isExecutableFile(atPath: gitPath) else {
            throw GitEngineError.gitNotFound
        }

        let gitPath = self.gitPath
        return try await withCheckedThrowingContinuation { continuation in
            // Process I/O is blocking; use a utility queue off the main thread.
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: gitPath)
                process.arguments = arguments
                process.currentDirectoryURL = workingDirectory
                // Deterministic output regardless of user git config.
                process.environment = ProcessInfo.processInfo.environment.merging(
                    ["GIT_PAGER": "cat", "LC_ALL": "en_US.UTF-8"],
                    uniquingKeysWith: { _, new in new }
                )

                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: GitEngineError.gitNotFound)
                    return
                }

                // Read fully before waiting to avoid pipe-buffer deadlock on
                // large diffs.
                let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()

                if process.terminationStatus != 0 {
                    let stderr = String(data: stderrData, encoding: .utf8) ?? ""
                    continuation.resume(throwing: GitEngineError.commandFailed(
                        command: arguments.joined(separator: " "),
                        exitCode: process.terminationStatus,
                        stderr: stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                    ))
                    return
                }

                let output = String(data: stdoutData, encoding: .utf8) ?? ""
                continuation.resume(returning: output)
            }
        }
    }
}
