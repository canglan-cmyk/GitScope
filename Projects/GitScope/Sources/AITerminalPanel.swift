import AppKit
import SwiftTerm

/// Which AI CLI tool to run in the terminal panel.
enum AIAgentTool: String, CaseIterable {
    case claudeCode = "claude"
    case codex = "codex"

    var displayName: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .codex: return "Codex"
        }
    }

    /// Locates the executable by searching common install locations and PATH.
    var resolvedPath: String? {
        let candidates = [
            "/opt/homebrew/bin/\(rawValue)",
            "/usr/local/bin/\(rawValue)",
            "\(NSHomeDirectory())/.local/bin/\(rawValue)",
            "\(NSHomeDirectory())/.npm-global/bin/\(rawValue)",
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        // Fall back to `which` through the user's login shell.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lic", "command -v \(rawValue)"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let output = String(
            data: pipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        )?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (output?.isEmpty == false) ? output : nil
    }
}

/// Right-hand panel embedding a terminal that runs an AI CLI tool
/// (Claude Code / Codex) in the repository directory.
final class AITerminalPanelController: NSViewController {

    // MARK: State

    /// Repository the terminal session should run in.
    var repositoryURL: URL? {
        didSet {
            guard repositoryURL != oldValue else { return }
            // Restart only if a session was already running.
            if terminalView != nil { restartSession() }
        }
    }

    private var terminalView: LocalProcessTerminalView?
    private let toolPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let restartButton = NSButton()
    private let placeholderLabel = NSTextField(wrappingLabelWithString: "")
    private var availableTools: [(tool: AIAgentTool, path: String)] = []

    // MARK: Lifecycle

    override func loadView() {
        view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false

        // Header bar: tool picker + restart.
        let header = NSStackView()
        header.orientation = .horizontal
        header.spacing = 6
        header.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
        header.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: "AI")
        title.font = .systemFont(ofSize: 11, weight: .semibold)
        title.textColor = .secondaryLabelColor

        toolPopup.controlSize = .small
        toolPopup.font = .systemFont(ofSize: 11)
        toolPopup.target = self
        toolPopup.action = #selector(toolChanged)

        restartButton.image = NSImage(
            systemSymbolName: "arrow.clockwise",
            accessibilityDescription: "重启会话"
        )
        restartButton.bezelStyle = .accessoryBarAction
        restartButton.isBordered = false
        restartButton.controlSize = .small
        restartButton.target = self
        restartButton.action = #selector(restartSession)
        restartButton.toolTip = "重启 AI 会话"

        header.addArrangedSubview(title)
        header.addArrangedSubview(toolPopup)
        header.addArrangedSubview(NSView()) // spacer
        header.addArrangedSubview(restartButton)

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        placeholderLabel.font = .systemFont(ofSize: 12)
        placeholderLabel.textColor = .secondaryLabelColor
        placeholderLabel.alignment = .center
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(header)
        view.addSubview(separator)
        view.addSubview(placeholderLabel)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.topAnchor),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 30),

            separator.topAnchor.constraint(equalTo: header.bottomAnchor),
            separator.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            placeholderLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            placeholderLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            placeholderLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
        ])

        detectTools()
    }

    // MARK: Tool detection

    private func detectTools() {
        toolPopup.removeAllItems()
        availableTools = []

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let found: [(AIAgentTool, String)] = AIAgentTool.allCases.compactMap { tool in
                tool.resolvedPath.map { (tool, $0) }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.availableTools = found
                if found.isEmpty {
                    self.placeholderLabel.stringValue = """
                    未找到 AI CLI 工具。

                    请安装 Claude Code (claude) 或 Codex (codex),
                    然后点击右上角 ⟳ 重试。
                    """
                    self.toolPopup.isEnabled = false
                } else {
                    self.toolPopup.addItems(withTitles: found.map(\.0.displayName))
                    self.toolPopup.isEnabled = true
                    self.placeholderLabel.stringValue = "打开一个仓库后启动 AI 会话"
                    self.startSessionIfReady()
                }
            }
        }
    }

    // MARK: Session management

    private var selectedTool: (tool: AIAgentTool, path: String)? {
        let index = toolPopup.indexOfSelectedItem
        guard availableTools.indices.contains(index) else { return availableTools.first }
        return availableTools[index]
    }

    private func startSessionIfReady() {
        guard terminalView == nil,
              let repositoryURL,
              let selected = selectedTool else { return }

        placeholderLabel.isHidden = true

        let term = LocalProcessTerminalView(frame: .zero)
        term.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(term)
        NSLayoutConstraint.activate([
            term.topAnchor.constraint(equalTo: view.topAnchor, constant: 31),
            term.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            term.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            term.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        terminalView = term

        // Launch the tool via login shell so the user's PATH/env applies,
        // with the working directory set to the repository root.
        var env = Terminal.getEnvironmentVariables(termName: "xterm-256color")
        env.append("LANG=en_US.UTF-8")
        term.startProcess(
            executable: "/bin/zsh",
            args: ["-lic", shellQuote(selected.path)],
            environment: env,
            currentDirectory: repositoryURL.path
        )
        view.window?.makeFirstResponder(term)
    }

    @objc func restartSession() {
        terminalView?.removeFromSuperview()
        terminalView = nil
        placeholderLabel.isHidden = false
        if availableTools.isEmpty {
            detectTools()
        } else {
            startSessionIfReady()
        }
    }

    @objc private func toolChanged() {
        restartSession()
    }

    /// Called by the window controller when a repository is opened.
    func activate(repository: URL) {
        repositoryURL = repository
        startSessionIfReady()
    }

    // MARK: Sending text

    /// Types text into the running AI tool's input box (no newline appended,
    /// so the user keeps control of when to send).
    func send(text: String) {
        guard let terminalView else { return }
        // Use bracketed paste so multi-line content lands in the input box
        // as a single paste instead of being executed line by line.
        let bracketedPaste = "\u{1b}[200~" + text + "\u{1b}[201~"
        terminalView.send(txt: bracketedPaste)
        view.window?.makeFirstResponder(terminalView)
    }

    var hasActiveSession: Bool { terminalView != nil }

    private func shellQuote(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
