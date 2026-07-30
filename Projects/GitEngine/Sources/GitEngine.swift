import Foundation
import DiffCore

// MARK: - Domain types

/// A git reference (branch, tag, or arbitrary revision).
public struct GitRef: Sendable, Hashable, Identifiable {
    public enum Kind: Sendable, Hashable {
        case localBranch
        case remoteBranch
        case tag
        case revision
    }

    public let name: String
    public let kind: Kind
    /// Full resolved name, e.g. `refs/heads/main`.
    public let fullName: String

    public var id: String { fullName }

    public init(name: String, kind: Kind, fullName: String) {
        self.name = name
        self.kind = kind
        self.fullName = fullName
    }
}

/// How two refs are compared.
public enum ComparisonMode: Sendable, Hashable {
    /// `git diff base..head` — direct tree-to-tree comparison.
    case twoDot
    /// `git diff base...head` — merge-base comparison, matching GitHub's
    /// compare and PR semantics.
    case threeDot
}

// MARK: - Engine protocol

/// Abstraction over "where diffs come from". Implementations may shell out
/// to the system git binary, use libgit2 in-process, or call the GitHub API.
public protocol GitEngine: Sendable {
    /// Verifies the directory is a git repository and returns its top level.
    func repositoryRoot(at url: URL) async throws -> URL
    /// Lists branches and tags of the repository.
    func refs(in repository: URL) async throws -> [GitRef]
    /// The currently checked out branch, if any.
    func currentBranch(in repository: URL) async throws -> GitRef?
    /// Computes the diff between two refs and returns the parsed document.
    func diff(
        in repository: URL,
        base: String,
        head: String,
        mode: ComparisonMode
    ) async throws -> DiffDocument
}

// MARK: - Errors

public enum GitEngineError: Error, LocalizedError, Equatable {
    case notARepository(path: String)
    case gitNotFound
    case commandFailed(command: String, exitCode: Int32, stderr: String)
    case unknownRef(String)

    public var errorDescription: String? {
        switch self {
        case .notARepository(let path):
            return "Not a git repository: \(path)"
        case .gitNotFound:
            return "The git executable could not be found."
        case .commandFailed(let command, let exitCode, let stderr):
            return "git \(command) failed (exit \(exitCode)): \(stderr)"
        case .unknownRef(let ref):
            return "Unknown ref: \(ref)"
        }
    }
}
