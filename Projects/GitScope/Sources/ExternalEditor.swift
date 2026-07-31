import AppKit

/// Opens files (with line-level positioning) in the user's code editor.
/// Detection is on-demand and cheap: we just probe well-known CLI paths.
@MainActor
enum ExternalEditor: String, CaseIterable {
    case xcode
    case vscode
    case cursor

    var displayName: String {
        switch self {
        case .xcode: return "Xcode"
        case .vscode: return "VS Code"
        case .cursor: return "Cursor"
        }
    }

    /// Candidate CLI paths, first hit wins.
    private var candidatePaths: [String] {
        switch self {
        case .xcode:
            return ["/usr/bin/xed"]
        case .vscode:
            return [
                "/opt/homebrew/bin/code",
                "/usr/local/bin/code",
                "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code",
            ]
        case .cursor:
            return [
                "/opt/homebrew/bin/cursor",
                "/usr/local/bin/cursor",
                "/Applications/Cursor.app/Contents/Resources/app/bin/cursor",
            ]
        }
    }

    var executablePath: String? {
        candidatePaths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static var installed: [ExternalEditor] {
        allCases.filter { $0.executablePath != nil }
    }

    /// The user's preferred editor (persisted), falling back to the first
    /// installed one.
    static var preferred: ExternalEditor? {
        get {
            if let raw = UserDefaults.standard.string(forKey: "PreferredExternalEditor"),
               let editor = ExternalEditor(rawValue: raw),
               editor.executablePath != nil {
                return editor
            }
            return installed.first
        }
        set {
            UserDefaults.standard.set(newValue?.rawValue, forKey: "PreferredExternalEditor")
        }
    }

    /// Opens `file` at `line` (1-based). Line may be nil to just open the file.
    func open(file: URL, line: Int?) {
        guard let executable = executablePath else { return }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        switch self {
        case .xcode:
            var args: [String] = []
            if let line { args += ["--line", String(line)] }
            args.append(file.path)
            process.arguments = args
        case .vscode, .cursor:
            if let line {
                process.arguments = ["--goto", "\(file.path):\(line)"]
            } else {
                process.arguments = [file.path]
            }
        }
        try? process.run()
    }
}
