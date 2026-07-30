import AppKit
import DiffCore
import DiffRenderKit
import GitEngine

/// Main window: NSSplitViewController with a sidebar (compare controls +
/// changed-files tree) and the virtualized diff list as content.
@MainActor
final class MainWindowController: NSWindowController, NSToolbarDelegate {

    private let engine: any GitEngine = GitCLIEngine()

    private var repositoryURL: URL? {
        didSet { updateWindowTitle() }
    }
    private var refs: [GitRef] = []
    private var diffTask: Task<Void, Never>?

    // MARK: Controls (live in the sidebar)

    private let openButton = NSButton(title: "打开仓库…", target: nil, action: nil)
    private let basePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let headPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let modePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let displayPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let themePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let statusLabel = NSTextField(labelWithString: "打开一个 Git 仓库开始对比")

    // MARK: View controllers

    private let sidebar = FileTreeSidebarController()
    private let diffList = DiffListViewController()
    private let splitViewController = NSSplitViewController()

    // MARK: Setup

    convenience init() {
        // Default to a comfortable size proportional to the screen.
        let screenFrame = NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1600, height: 1000)
        let defaultSize = NSSize(
            width: min(1440, screenFrame.width * 0.85),
            height: min(940, screenFrame.height * 0.9)
        )

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: defaultSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.minSize = NSSize(width: 960, height: 620)
        window.center()
        window.setFrameAutosaveName("MainWindow")

        // A previously saved tiny frame would override the default; snap it
        // back to something usable.
        if window.frame.width < 960 || window.frame.height < 620 {
            window.setContentSize(defaultSize)
            window.center()
        }

        window.titlebarAppearsTransparent = false
        self.init(window: window)
        setup()
    }

    private func setup() {
        guard let window else { return }
        updateWindowTitle()

        setupControls()
        setupSidebarControls()

        // Split view: sidebar + content.
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 220
        sidebarItem.maximumThickness = 400
        sidebarItem.canCollapse = true

        let contentItem = NSSplitViewItem(viewController: diffList)
        contentItem.minimumThickness = 400

        splitViewController.addSplitViewItem(sidebarItem)
        splitViewController.addSplitViewItem(contentItem)

        window.contentViewController = splitViewController

        // Toolbar: sidebar toggle on the left, open-repository on the right.
        let toolbar = NSToolbar(identifier: "MainToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        window.toolbarStyle = .unified

        // Sidebar → diff navigation.
        sidebar.onSelectFile = { [weak self] fileIndex in
            self?.diffList.scrollToFile(at: fileIndex)
        }
    }

    private func setupControls() {
        openButton.target = self
        openButton.action = #selector(openRepository)

        for popup in [basePopup, headPopup] {
            popup.target = self
            popup.action = #selector(selectionChanged)
            popup.isEnabled = false
        }

        modePopup.addItems(withTitles: ["三点比较 (A...B)", "两点比较 (A..B)"])
        modePopup.target = self
        modePopup.action = #selector(selectionChanged)

        displayPopup.addItems(withTitles: ["Unified 单栏", "Split 双栏"])
        displayPopup.target = self
        displayPopup.action = #selector(displayModeChanged)

        themePopup.addItems(withTitles: DiffTheme.builtIn.map(\.name))
        themePopup.target = self
        themePopup.action = #selector(themeChanged)

        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.lineBreakMode = .byTruncatingTail
    }

    private func setupSidebarControls() {
        let stack = sidebar.controlsStack

        func labeledRow(_ label: String, _ control: NSView) -> NSStackView {
            let text = NSTextField(labelWithString: label)
            text.font = .systemFont(ofSize: 11)
            text.textColor = .secondaryLabelColor
            text.setContentHuggingPriority(.required, for: .horizontal)
            let row = NSStackView(views: [text, control])
            row.orientation = .horizontal
            row.spacing = 6
            return row
        }

        let swapButton = NSButton(title: "⇄ 交换", target: self, action: #selector(swapRefs))
        swapButton.controlSize = .small
        swapButton.bezelStyle = .rounded

        stack.addArrangedSubview(labeledRow("base", basePopup))
        stack.addArrangedSubview(labeledRow("head", headPopup))
        stack.addArrangedSubview(swapButton)
        stack.addArrangedSubview(modePopup)
        stack.addArrangedSubview(labeledRow("显示", displayPopup))
        stack.addArrangedSubview(labeledRow("主题", themePopup))
        stack.addArrangedSubview(statusLabel)

        // Fixed widths so controls don't stretch with the window.
        for control in [basePopup, headPopup, modePopup, displayPopup, themePopup] {
            control.translatesAutoresizingMaskIntoConstraints = false
        }
        NSLayoutConstraint.activate([
            basePopup.widthAnchor.constraint(equalToConstant: 160),
            headPopup.widthAnchor.constraint(equalToConstant: 160),
            modePopup.widthAnchor.constraint(equalToConstant: 150),
            displayPopup.widthAnchor.constraint(equalToConstant: 150),
            themePopup.widthAnchor.constraint(equalToConstant: 150),
        ])
    }

    private func updateWindowTitle() {
        let repoName = repositoryURL?.lastPathComponent
        window?.title = repoName.map { "GitScope — \($0)" } ?? "GitScope"
    }

    // MARK: NSToolbarDelegate

    private static let openRepoItemID = NSToolbarItem.Identifier("OpenRepository")

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        guard itemIdentifier == Self.openRepoItemID else { return nil }
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = "打开仓库"
        item.paletteLabel = "打开仓库"
        item.toolTip = "打开一个本地 Git 仓库"
        item.image = NSImage(systemSymbolName: "folder.badge.plus", accessibilityDescription: "打开仓库")
        item.target = self
        item.action = #selector(openRepository)
        item.isBordered = true
        return item
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, .flexibleSpace, Self.openRepoItemID]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, .flexibleSpace, Self.openRepoItemID]
    }

    // MARK: Actions

    @objc private func openRepository() {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "选择一个 Git 仓库目录"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor [weak self] in
                await self?.loadRepository(at: url)
            }
        }
    }

    private func loadRepository(at url: URL) async {
        do {
            let root = try await engine.repositoryRoot(at: url)
            let refs = try await engine.refs(in: root)
            let current = try await engine.currentBranch(in: root)

            self.repositoryURL = root
            self.refs = refs
            populateRefPopups(current: current)
            statusLabel.stringValue = "已加载 \(refs.count) 个引用"
            refreshDiff()
        } catch {
            showErrorAlert(error)
        }
    }

    private func populateRefPopups(current: GitRef?) {
        let branchNames = refs
            .filter { $0.kind == .localBranch || $0.kind == .remoteBranch }
            .map(\.name)

        for popup in [basePopup, headPopup] {
            popup.removeAllItems()
            popup.addItems(withTitles: branchNames)
            popup.isEnabled = !branchNames.isEmpty
        }

        if let defaultBase = branchNames.first(where: { $0 == "main" || $0 == "master" }) {
            basePopup.selectItem(withTitle: defaultBase)
        }
        if let current, branchNames.contains(current.name) {
            headPopup.selectItem(withTitle: current.name)
        }
    }

    @objc private func selectionChanged() {
        refreshDiff()
    }

    @objc private func swapRefs() {
        let base = basePopup.titleOfSelectedItem
        let head = headPopup.titleOfSelectedItem
        if let base { headPopup.selectItem(withTitle: base) }
        if let head { basePopup.selectItem(withTitle: head) }
        refreshDiff()
    }

    @objc private func displayModeChanged() {
        diffList.displayMode = displayPopup.indexOfSelectedItem == 1 ? .split : .unified
    }

    @objc private func themeChanged() {
        let index = themePopup.indexOfSelectedItem
        guard DiffTheme.builtIn.indices.contains(index) else { return }
        diffList.theme = DiffTheme.builtIn[index]
    }

    // MARK: Diff loading

    private func refreshDiff() {
        guard let repositoryURL,
              let base = basePopup.titleOfSelectedItem,
              let head = headPopup.titleOfSelectedItem
        else { return }

        let mode: ComparisonMode = modePopup.indexOfSelectedItem == 0 ? .threeDot : .twoDot

        statusLabel.stringValue = "对比中…"
        diffTask?.cancel()
        diffTask = Task { [weak self] in
            guard let self else { return }
            do {
                let document = try await self.engine.diff(
                    in: repositoryURL, base: base, head: head, mode: mode
                )
                guard !Task.isCancelled else { return }
                self.diffList.document = document
                self.sidebar.document = document
                self.statusLabel.stringValue =
                    "\(document.files.count) 个文件 · +\(document.totalAdditions) −\(document.totalDeletions)"
            } catch is CancellationError {
                // Superseded by a newer request.
            } catch {
                self.statusLabel.stringValue = "对比失败"
                self.showErrorAlert(error)
            }
        }
    }

    private func showErrorAlert(_ error: Error) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "操作失败"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.beginSheetModal(for: window)
    }
}
