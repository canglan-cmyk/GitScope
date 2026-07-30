import Foundation
import Testing
import DiffCore
@testable import GitEngine

/// Integration tests: build a real throwaway repository with the system git,
/// then exercise the engine against it.
@Suite("GitCLIEngine", .serialized)
struct GitCLIEngineTests {

    // MARK: Fixture

    /// Creates a temp repo with two branches:
    /// - main: file.txt ("hello\nworld\n"), base.txt
    /// - feature: file.txt modified + added.txt, branched from main's first commit
    private func makeFixtureRepository() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("gitscope-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        func git(_ args: String...) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = Array(args)
            process.currentDirectoryURL = root
            process.environment = ProcessInfo.processInfo.environment.merging([
                "GIT_AUTHOR_NAME": "Test", "GIT_AUTHOR_EMAIL": "t@t.t",
                "GIT_COMMITTER_NAME": "Test", "GIT_COMMITTER_EMAIL": "t@t.t",
            ], uniquingKeysWith: { _, new in new })
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            try process.run()
            process.waitUntilExit()
        }

        func write(_ name: String, _ content: String) throws {
            try content.write(
                to: root.appendingPathComponent(name),
                atomically: true,
                encoding: .utf8
            )
        }

        try git("init", "-b", "main")
        try write("file.txt", "hello\nworld\n")
        try write("base.txt", "base\n")
        try git("add", ".")
        try git("commit", "-m", "initial")

        try git("checkout", "-b", "feature")
        try write("file.txt", "hello\nbrave new world\n")
        try write("added.txt", "fresh\n")
        try git("add", ".")
        try git("commit", "-m", "feature work")

        try git("checkout", "main")
        try write("base.txt", "base evolved\n")
        try git("add", ".")
        try git("commit", "-m", "main moves on")

        return root
    }

    // MARK: Tests

    @Test("识别仓库根目录;非仓库抛错")
    func repositoryRoot() async throws {
        let repo = try makeFixtureRepository()
        defer { try? FileManager.default.removeItem(at: repo) }

        let engine = GitCLIEngine()
        let found = try await engine.repositoryRoot(at: repo)
        #expect(found.resolvingSymlinksInPath().path == repo.resolvingSymlinksInPath().path)

        let notRepo = URL(fileURLWithPath: NSTemporaryDirectory())
        await #expect(throws: GitEngineError.self) {
            _ = try await engine.repositoryRoot(at: notRepo)
        }
    }

    @Test("列出分支引用与当前分支")
    func refsAndCurrentBranch() async throws {
        let repo = try makeFixtureRepository()
        defer { try? FileManager.default.removeItem(at: repo) }

        let engine = GitCLIEngine()
        let refs = try await engine.refs(in: repo)
        let branchNames = refs.filter { $0.kind == .localBranch }.map(\.name).sorted()
        #expect(branchNames == ["feature", "main"])

        let current = try await engine.currentBranch(in: repo)
        #expect(current?.name == "main")
    }

    @Test("两分支 three-dot diff:只含 feature 侧改动")
    func threeDotDiff() async throws {
        let repo = try makeFixtureRepository()
        defer { try? FileManager.default.removeItem(at: repo) }

        let engine = GitCLIEngine()
        let document = try await engine.diff(
            in: repo, base: "main", head: "feature", mode: .threeDot
        )

        // three-dot 相对 merge-base,不应包含 main 侧 base.txt 的后续演进
        let paths = document.files.map(\.canonicalPath).sorted()
        #expect(paths == ["added.txt", "file.txt"])

        let fileDiff = try #require(document.files.first { $0.canonicalPath == "file.txt" })
        #expect(fileDiff.change == .modified)
        #expect(fileDiff.deletionCount == 1)
        #expect(fileDiff.additionCount == 1)

        // 行内高亮已标注:"world" → "brave new world" 是纯插入,
        // 新增行高亮 "brave new ",删除行无剩余区间(nil)
        let hunk = try #require(fileDiff.hunks.first)
        let added = try #require(hunk.lines.first { $0.change == .addition })
        #expect(added.intralineHighlight == 0..<10)
        let deleted = try #require(hunk.lines.first { $0.change == .deletion })
        #expect(deleted.intralineHighlight == nil)
    }

    @Test("两分支 two-dot diff:包含双侧差异")
    func twoDotDiff() async throws {
        let repo = try makeFixtureRepository()
        defer { try? FileManager.default.removeItem(at: repo) }

        let engine = GitCLIEngine()
        let document = try await engine.diff(
            in: repo, base: "main", head: "feature", mode: .twoDot
        )
        // two-dot 直接比树,main 侧演进的 base.txt 也会出现(表现为回退)
        let paths = document.files.map(\.canonicalPath).sorted()
        #expect(paths.contains("base.txt"))
    }

    @Test("未知引用报 commandFailed")
    func unknownRef() async throws {
        let repo = try makeFixtureRepository()
        defer { try? FileManager.default.removeItem(at: repo) }

        let engine = GitCLIEngine()
        await #expect(throws: GitEngineError.self) {
            _ = try await engine.diff(
                in: repo, base: "nonexistent", head: "feature", mode: .threeDot
            )
        }
    }
}
