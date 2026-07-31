import Foundation

/// Category of a changed file, used to group the file tree so reviewers can
/// separate the signal (core code) from the noise (lockfiles, generated
/// output, docs).
public enum ChangeCategory: String, CaseIterable, Sendable {
    case core       // production source code — the main act
    case tests      // test code
    case config     // build & project configuration
    case generated  // lockfiles, snapshots, generated output
    case docs       // documentation
    case assets     // images, fonts, other binary-ish resources

    /// Display order: signal first, noise last.
    public var sortOrder: Int {
        switch self {
        case .core: return 0
        case .tests: return 1
        case .config: return 2
        case .assets: return 3
        case .docs: return 4
        case .generated: return 5
        }
    }

    public var displayNameKey: String {
        switch self {
        case .core: return "核心代码"
        case .tests: return "测试"
        case .config: return "配置与构建"
        case .generated: return "生成物"
        case .docs: return "文档"
        case .assets: return "资源"
        }
    }

    /// Whether the group should start collapsed (noise categories).
    public var collapsedByDefault: Bool {
        switch self {
        case .generated, .docs, .assets: return true
        case .core, .tests, .config: return false
        }
    }
}

/// Rule-based classifier: no AI, just filename/path conventions that cover
/// the overwhelming majority of real-world repositories.
public enum ChangeClassifier {

    public static func classify(path: String) -> ChangeCategory {
        let lower = path.lowercased()
        let fileName = (lower as NSString).lastPathComponent
        let ext = (fileName as NSString).pathExtension

        // Generated / lock artifacts — check first, they masquerade as config.
        let generatedNames: Set<String> = [
            "package.resolved", "package-lock.json", "yarn.lock", "pnpm-lock.yaml",
            "podfile.lock", "cartfile.resolved", "gemfile.lock", "poetry.lock",
            "cargo.lock", "composer.lock", "go.sum", "mix.lock", "flake.lock",
        ]
        if generatedNames.contains(fileName) { return .generated }
        if lower.contains("__snapshots__") || fileName.hasSuffix(".snap")
            || fileName.hasSuffix(".generated.swift") || fileName.hasSuffix(".g.dart")
            || fileName.hasSuffix(".pb.swift") || fileName.hasSuffix(".pb.go")
            || fileName.hasSuffix(".min.js") || fileName.hasSuffix(".min.css")
            || lower.contains("/generated/") || lower.hasPrefix("generated/")
            || lower.contains("/derived/") {
            return .generated
        }

        // Tests.
        if lower.contains("/tests/") || lower.hasPrefix("tests/")
            || lower.contains("/test/") || lower.hasPrefix("test/")
            || lower.contains("/__tests__/") || lower.contains("/spec/")
            || fileName.hasSuffix("tests.swift") || fileName.hasSuffix("test.swift")
            || fileName.hasSuffix(".test.ts") || fileName.hasSuffix(".test.tsx")
            || fileName.hasSuffix(".test.js") || fileName.hasSuffix(".spec.ts")
            || fileName.hasSuffix(".spec.js") || fileName.hasSuffix("_test.go")
            || fileName.hasSuffix("_test.py") || fileName.hasPrefix("test_") {
            return .tests
        }

        // Documentation.
        let docExts: Set<String> = ["md", "markdown", "rst", "adoc", "txt"]
        if docExts.contains(ext) || lower.contains("/docs/") || lower.hasPrefix("docs/") {
            return .docs
        }

        // Assets.
        let assetExts: Set<String> = [
            "png", "jpg", "jpeg", "gif", "webp", "svg", "pdf", "ico", "icns",
            "ttf", "otf", "woff", "woff2", "mp3", "wav", "mp4", "mov",
            "xcassets", "car", "strings", "xcstrings", "stringsdict",
        ]
        if assetExts.contains(ext) || lower.contains(".xcassets/") {
            return .assets
        }

        // Configuration & build.
        let configNames: Set<String> = [
            "makefile", "dockerfile", "rakefile", "fastfile", "appfile", "matchfile",
            ".gitignore", ".gitattributes", ".editorconfig", ".swiftlint.yml",
            ".swiftformat", ".prettierrc", ".eslintrc", "tuist.swift", "workspace.swift",
            "project.swift", "package.swift", "podfile", "cartfile", "gemfile",
            "info.plist", "entitlements.plist",
        ]
        let configExts: Set<String> = [
            "yml", "yaml", "toml", "ini", "plist", "entitlements", "xcconfig",
            "xcscheme", "pbxproj", "xcworkspacedata", "modulemap", "json",
            "lock", "properties", "gradle", "cfg", "conf",
        ]
        if configNames.contains(fileName) || configExts.contains(ext)
            || lower.contains("/.github/") || lower.hasPrefix(".github/")
            || lower.contains("/scripts/") || lower.hasPrefix("scripts/")
            || lower.contains("/fastlane/") {
            return .config
        }

        return .core
    }
}

// MARK: - Protagonist scoring

extension FileDiff {
    /// A crude but effective "how central is this file to the change" score:
    /// total churn. Used to order files by importance instead of
    /// alphabetically. (Reference-graph centrality can refine this later.)
    public var churn: Int { additionCount + deletionCount }
}
