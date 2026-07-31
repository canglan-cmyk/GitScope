import AppKit
import DiffCore
import DiffRenderKit
import GitEngine

/// Main window: NSSplitViewController with a sidebar (compare controls +
/// changed-files tree) and the virtualized diff list as content.
@MainActor
final class MainWindowController: NSWindowController, NSToolbarDelegate, NSSearchFieldDelegate {

    private let engine = GitCLIEngine()
    private let referenceFinder = ReferenceFinder()

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
    private var workspaceWatcher: WorkspaceWatcher?

    // Commit timeline
    private var commits: [GitCommit] = []
    private var selectedCommitSHA: String? // nil = whole-range diff
    private let commitPopup = NSPopUpButton(frame: .zero, pullsDown: false)

    // Search bar (hidden until ⌘F)
    private let searchBar = NSView()
    private let searchField = NSSearchField()
    private let searchResultLabel = NSTextField(labelWithString: "")
    private let searchScopeControl = NSSegmentedControl(
        labels: ["全部行", "仅变更行"], trackingMode: .selectOne, target: nil, action: nil
    )
    private var searchBarVisible = false

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
        sidebar.onOpenInEditor = { [weak self] fileIndex in
            self?.openFileInEditor(fileIndex: fileIndex, line: nil)
        }

        diffList.onSearchResultsChanged = { [weak self] count, current in
            self?.searchResultLabel.stringValue = count == 0 ? "无结果" : "\(current)/\(count)"
        }

        // Right-click actions inside the diff.
        diffList.onFindReferences = { [weak self] context in
            self?.findReferences(for: context)
        }
        diffList.onOpenSelectionInEditor = { [weak self] context in
            self?.openInEditor(path: context.filePath, line: context.lineNumber)
        }

        // ⌘F anywhere in the window opens the search bar. Key events don't
        // reliably reach the window controller, so use a local monitor.
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            if event.modifierFlags.contains(.command),
               event.charactersIgnoringModifiers?.lowercased() == "f" {
                self.showSearchBar()
                return nil
            }
            if event.keyCode == 53, self.searchBarVisible { // Esc
                self.hideSearchBar()
                return nil
            }
            return event
        }

        setupSearchBar()
    }

    // MARK: Reference finding

    private func findReferences(for context: DiffListViewController.SelectionContext) {
        guard let repositoryURL, let window else { return }
        let word = context.selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty else { return }

        let diffPaths = Set(diffList.document?.files.map(\.canonicalPath) ?? [])
        statusLabel.stringValue = "查找“\(word)”的引用…"

        Task { [weak self] in
            guard let self else { return }
            do {
                let raw = try await self.referenceFinder.findReferences(
                    to: word, in: repositoryURL
                )
                let annotated = self.referenceFinder.annotate(raw, diffPaths: diffPaths)
                self.statusLabel.stringValue =
                    "“\(word)”：\(annotated.count) 处引用"

                let panel = ReferencePanelController(identifier: word, references: annotated)
                let sheetWindow = NSWindow(contentViewController: panel)
                sheetWindow.styleMask = [.titled, .closable]
                sheetWindow.title = "引用查找"
                window.beginSheet(sheetWindow) { _ in }

                // Double-click a row: close the sheet and jump to the editor.
                panel.onJump = { [weak self] path, line in
                    window.endSheet(sheetWindow)
                    self?.openInEditor(path: path, line: line)
                }
                panel.onClose = {
                    window.endSheet(sheetWindow)
                }
            } catch {
                self.statusLabel.stringValue = "引用查找失败"
            }
        }
    }

    private func openInEditor(path: String, line: Int?) {
        guard let repositoryURL else { return }
        let fileURL = repositoryURL.appendingPathComponent(path)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            statusLabel.stringValue = "文件不在工作区：\(path)"
            return
        }
        guard let editor = ExternalEditor.preferred else {
            statusLabel.stringValue = "未检测到可用编辑器（Xcode/VS Code/Cursor）"
            return
        }
        editor.open(file: fileURL, line: line)
    }

    private func setupSearchBar() {
        guard let contentView = window?.contentView else { return }

        searchBar.wantsLayer = true
        searchBar.isHidden = true

        let material = NSVisualEffectView()
        material.material = .headerView
        material.blendingMode = .withinWindow

        searchField.placeholderString = "在 diff 中搜索（回车下一个，⇧回车上一个）"
        searchField.delegate = self
        searchField.target = self
        searchField.action = #selector(searchFieldAction)

        searchScopeControl.selectedSegment = 0
        searchScopeControl.target = self
        searchScopeControl.action = #selector(searchScopeChanged)
        searchScopeControl.controlSize = .small

        searchResultLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        searchResultLabel.textColor = .secondaryLabelColor

        let closeButton = NSButton(
            image: NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "关闭")!,
            target: self, action: #selector(hideSearchBar)
        )
        closeButton.isBordered = false

        let stack = NSStackView(views: [searchField, searchScopeControl, searchResultLabel, closeButton])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)

        material.translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        searchBar.translatesAutoresizingMaskIntoConstraints = false
        searchBar.addSubview(material)
        searchBar.addSubview(stack)
        contentView.addSubview(searchBar)

        NSLayoutConstraint.activate([
            material.topAnchor.constraint(equalTo: searchBar.topAnchor),
            material.bottomAnchor.constraint(equalTo: searchBar.bottomAnchor),
            material.leadingAnchor.constraint(equalTo: searchBar.leadingAnchor),
            material.trailingAnchor.constraint(equalTo: searchBar.trailingAnchor),

            stack.topAnchor.constraint(equalTo: searchBar.topAnchor),
            stack.bottomAnchor.constraint(equalTo: searchBar.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: searchBar.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: searchBar.trailingAnchor),

            searchBar.topAnchor.constraint(equalTo: contentView.safeAreaLayoutGuide.topAnchor),
            searchBar.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8),
            searchBar.widthAnchor.constraint(lessThanOrEqualToConstant: 560),
            searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 260),
        ])
    }

    // MARK: Search actions

    @objc private func showSearchBar() {
        searchBar.isHidden = false
        searchBarVisible = true
        window?.makeFirstResponder(searchField)
    }

    @objc private func hideSearchBar() {
        searchBar.isHidden = true
        searchBarVisible = false
        diffList.clearSearch()
        searchResultLabel.stringValue = ""
    }

    @objc private func searchFieldAction() {
        // Return pressed inside the field: advance to next match.
        if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
            diffList.previousMatch()
        } else if !diffList.searchMatches.isEmpty {
            diffList.nextMatch()
        } else {
            diffList.search(searchField.stringValue)
        }
    }

    @objc private func searchScopeChanged() {
        diffList.searchScope = searchScopeControl.selectedSegment == 1
            ? .changedLinesOnly : .allLines
    }

    func controlTextDidChange(_ obj: Notification) {
        guard (obj.object as? NSSearchField) === searchField else { return }
        let query = searchField.stringValue
        if query.isEmpty {
            diffList.clearSearch()
            searchResultLabel.stringValue = ""
        } else {
            diffList.search(query)
        }
    }

    // MARK: External editor

    private func openFileInEditor(fileIndex: Int, line: Int?) {
        guard let document = diffList.document,
              document.files.indices.contains(fileIndex) else { return }
        openInEditor(path: document.files[fileIndex].canonicalPath, line: line)
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

        commitPopup.target = self
        commitPopup.action = #selector(commitSelectionChanged)
        commitPopup.isEnabled = false

        stack.addArrangedSubview(labeledRow("base", basePopup))
        stack.addArrangedSubview(labeledRow("head", headPopup))
        stack.addArrangedSubview(swapButton)
        stack.addArrangedSubview(modePopup)
        stack.addArrangedSubview(labeledRow("提交", commitPopup))
        stack.addArrangedSubview(labeledRow("显示", displayPopup))
        stack.addArrangedSubview(labeledRow("主题", themePopup))
        stack.addArrangedSubview(statusLabel)

        // Fixed widths so controls don't stretch with the window.
        for control in [basePopup, headPopup, modePopup, displayPopup, themePopup, commitPopup] {
            control.translatesAutoresizingMaskIntoConstraints = false
        }
        NSLayoutConstraint.activate([
            basePopup.widthAnchor.constraint(equalToConstant: 160),
            headPopup.widthAnchor.constraint(equalToConstant: 160),
            modePopup.widthAnchor.constraint(equalToConstant: 150),
            commitPopup.widthAnchor.constraint(equalToConstant: 160),
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

            // Watch the working tree: external edits (editor, AI tools,
            // checkouts) auto-refresh the diff.
            workspaceWatcher?.invalidate()
            workspaceWatcher = WorkspaceWatcher(url: root) { [weak self] in
                self?.refreshDiff()
            }

            refreshDiff()
        } catch {
            showErrorAlert(error)
        }
    }

    @objc private func commitSelectionChanged() {
        let index = commitPopup.indexOfSelectedItem
        if index <= 0 {
            selectedCommitSHA = nil
        } else if commits.indices.contains(index - 1) {
            selectedCommitSHA = commits[index - 1].sha
        }
        refreshDiff()
    }

    private func reloadCommits(base: String, head: String) {
        guard let repositoryURL else { return }
        Task { [weak self] in
            guard let self else { return }
            let commits = (try? await self.engine.commits(
                in: repositoryURL, base: base, head: head
            )) ?? []
            self.commits = commits
            self.selectedCommitSHA = nil
            self.commitPopup.removeAllItems()
            self.commitPopup.addItem(withTitle: "全部变更 (\(commits.count) 个提交)")
            for commit in commits {
                let title = "\(commit.shortSHA) \(commit.subject)"
                self.commitPopup.addItem(withTitle: String(title.prefix(60)))
            }
            self.commitPopup.isEnabled = !commits.isEmpty
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
        selectedCommitSHA = nil
        commitPopup.selectItem(at: 0)
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
        let commitSHA = selectedCommitSHA

        statusLabel.stringValue = "对比中…"
        diffTask?.cancel()
        diffTask = Task { [weak self] in
            guard let self else { return }
            do {
                let document: DiffDocument
                if let commitSHA {
                    document = try await self.engine.commitDiff(
                        in: repositoryURL, sha: commitSHA
                    )
                } else {
                    document = try await self.engine.diff(
                        in: repositoryURL, base: base, head: head, mode: mode
                    )
                }
                guard !Task.isCancelled else { return }
                self.diffList.document = document
                self.sidebar.document = document
                let prefix = commitSHA.map { _ in "[单个提交] " } ?? ""
                self.statusLabel.stringValue = prefix +
                    "\(document.files.count) 个文件 · +\(document.totalAdditions) −\(document.totalDeletions)"
                if commitSHA == nil {
                    self.reloadCommits(base: base, head: head)
                }
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
