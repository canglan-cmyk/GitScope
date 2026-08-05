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

    // PR preview mode. When non-nil, the diff shows a fetched pull request
    // and the branch pickers are hidden to avoid two conflicting sources of
    // truth in the sidebar.
    private var activePullRequest: (pr: PullRequest, base: String, head: String)?
    private let prBanner = NSStackView()
    private let prTitleLabel = NSTextField(labelWithString: "")
    private let prRefsLabel = NSTextField(labelWithString: "")
    private var branchControlRows: [NSView] = []

    // Search panel (right-side overlay, hidden until ⌘F)
    private let searchPanel = SearchResultsPanel()
    private let commentsPanel = CommentsPanel()
    private var searchBarVisible = false
    private let gitHubClient = GitHubClient()
    private var repoRemoteURL: String?
    private var searchField: NSSearchField { searchPanel.searchField }

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
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
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

        // Search and Comments panels are now embedded in the sidebar navigator tabs.
        sidebar.searchContentView = searchPanel
        sidebar.commentsContentView = commentsPanel
        commentsPanel.onClose = { [weak self] in
            self?.sidebar.showFilesTab()
        }
        commentsPanel.onSelectComment = { [weak self] comment in
            self?.jumpToComment(comment)
        }

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
            guard let self else { return }
            self.searchPanel.update(
                matches: self.diffList.searchMatches,
                currentIndex: current - 1
            )
        }
        searchPanel.onSelectMatch = { [weak self] index in
            self?.diffList.goToMatch(at: index)
        }
        searchPanel.onClose = { [weak self] in
            self?.hideSearchBar()
        }

        // Diff area: review button on file headers (PR mode).
        diffList.isFileReviewed = { [weak self] fileIndex in
            self?.sidebar.isReviewed(fileIndex: fileIndex) ?? false
        }
        diffList.onToggleFileReview = { [weak self] fileIndex in
            guard let self else { return }
            self.sidebar.toggleReviewed(fileIndex: fileIndex)
            // Auto-collapse reviewed files, expand when un-reviewed.
            let isNowReviewed = self.sidebar.isReviewed(fileIndex: fileIndex)
            if isNowReviewed {
                self.diffList.collapseFile(at: fileIndex)
            } else {
                self.diffList.expandFile(at: fileIndex)
            }
        }

        // PR browser: pick a PR → fetch its refs → local diff.
        sidebar.pullRequestPanel.onSelectPullRequest = { [weak self] pr in
            self?.showPullRequest(pr)
        }

        // Right-click actions inside the diff.
        diffList.onFindReferences = { [weak self] context in
            self?.findReferences(for: context)
        }
        diffList.onOpenSelectionInEditor = { [weak self] context in
            self?.openInEditor(path: context.filePath, line: context.lineNumber)
        }

        // Expand context: increase context lines and re-diff.
        diffList.onExpandContext = { [weak self] in
            guard let self else { return }
            self.contextLines = min(self.contextLines + 10, 999)
            self.refreshDiff()
        }

        // Image preview: load image data from git for binary image files.
        diffList.imageForFile = { [weak self] fileIndex in
            guard let self,
                  let document = self.diffList.document,
                  document.files.indices.contains(fileIndex),
                  let repositoryURL = self.repositoryURL
            else { return nil }
            let file = document.files[fileIndex]
            let path = file.canonicalPath
            // Determine which ref to use (head for additions/modifications).
            let ref: String
            if let active = self.activePullRequest {
                ref = active.head
            } else if let head = self.headPopup.titleOfSelectedItem {
                ref = head
            } else {
                return nil
            }
            // Synchronous git show to get image data.
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["show", "\(ref):\(path)"]
            process.currentDirectoryURL = repositoryURL
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                guard process.terminationStatus == 0, !data.isEmpty else { return nil }
                return NSImage(data: data)
            } catch {
                return nil
            }
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
        searchField.delegate = self
        searchField.target = self
        searchField.action = #selector(searchFieldAction)
        searchPanel.scopeControl.target = self
        searchPanel.scopeControl.action = #selector(searchScopeChanged)
    }

    // MARK: Search actions

    @objc private func showSearchBar() {
        searchBarVisible = true
        sidebar.showSearchTab()
        searchPanel.focusSearchField()
    }
    @objc private func hideSearchBar() {
        searchBarVisible = false
        sidebar.showFilesTab()
        diffList.clearSearch()
        searchPanel.clear()
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
        diffList.searchScope = searchPanel.scopeControl.selectedSegment == 1
            ? .changedLinesOnly : .allLines
    }

    func controlTextDidChange(_ obj: Notification) {
        guard (obj.object as? NSSearchField) === searchField else { return }
        let query = searchField.stringValue
        if query.isEmpty {
            diffList.clearSearch()
            searchPanel.clear()
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
        // PR mode banner (hidden until a PR is opened).
        prTitleLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        prTitleLabel.lineBreakMode = .byTruncatingTail
        prTitleLabel.maximumNumberOfLines = 2
        prRefsLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        prRefsLabel.textColor = .secondaryLabelColor
        prRefsLabel.lineBreakMode = .byTruncatingMiddle
        let exitPRButton = NSButton(
            title: "← 返回分支对比", target: self, action: #selector(exitPullRequestMode)
        )
        exitPRButton.controlSize = .small
        exitPRButton.bezelStyle = .rounded
        prBanner.orientation = .vertical
        prBanner.alignment = .leading
        prBanner.spacing = 4
        prBanner.addArrangedSubview(prTitleLabel)
        prBanner.addArrangedSubview(prRefsLabel)
        prBanner.addArrangedSubview(exitPRButton)
        prBanner.isHidden = true
        // Add PR banner to sidebar's prBannerContainer.
        sidebar.prBannerView = prBanner
        // Branch controls now live in the toolbar.
        commitPopup.target = self
        commitPopup.action = #selector(commitSelectionChanged)
        commitPopup.isEnabled = false
        branchControlRows = []
    }

    private func updateWindowTitle() {
        let repoName = repositoryURL?.lastPathComponent
        window?.title = repoName.map { "GitScope — \($0)" } ?? "GitScope"
    }

        // MARK: NSToolbarDelegate

    private static let openRepoItemID = NSToolbarItem.Identifier("OpenRepository")
    private static let branchItemID = NSToolbarItem.Identifier("BranchControls")
    private static let statusItemID = NSToolbarItem.Identifier("StatusLabel")

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch itemIdentifier {
        case Self.openRepoItemID:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "打开仓库"
            item.toolTip = "打开一个本地 Git 仓库"
            item.image = NSImage(systemSymbolName: "folder.badge.plus", accessibilityDescription: "打开仓库")
            item.target = self
            item.action = #selector(openRepository)
            item.isBordered = true
            return item
        case Self.branchItemID:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "分支"
            // Compact row: base ↔ head + mode + commit + display
            let row = NSStackView()
            row.orientation = .horizontal
            row.spacing = 6
            row.alignment = .centerY
            basePopup.controlSize = .small
            headPopup.controlSize = .small
            modePopup.controlSize = .small
            commitPopup.controlSize = .small
            displayPopup.controlSize = .small
            let arrowLabel = NSTextField(labelWithString: "→")
            arrowLabel.font = .systemFont(ofSize: 11)
            arrowLabel.textColor = .secondaryLabelColor
            row.addArrangedSubview(basePopup)
            row.addArrangedSubview(arrowLabel)
            row.addArrangedSubview(headPopup)
            row.addArrangedSubview(modePopup)
            row.addArrangedSubview(commitPopup)
            row.addArrangedSubview(displayPopup)
            item.view = row
            return item
        case Self.statusItemID:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "状态"
            statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            item.view = statusLabel
            return item
        default:
            return nil
        }
    }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, Self.branchItemID, .flexibleSpace, Self.statusItemID, Self.openRepoItemID]
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, Self.branchItemID, .flexibleSpace, Self.statusItemID, Self.openRepoItemID]
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

            // A fresh repository always starts in branch-comparison mode.
            activePullRequest = nil
            prBanner.isHidden = true
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

            // Point the PR browser at this repo's GitHub remote.
            let remote = try? await engine.remoteURL(in: root)
            self.repoRemoteURL = remote
            sidebar.pullRequestPanel.setRepository(remoteURL: remote)

            refreshDiff()
        } catch {
            showErrorAlert(error)
        }
    }

    // MARK: Pull request preview

    /// Fetches the PR head + base into local refs and diffs them locally —
    /// the full PR diff without opening a browser, and offline afterwards.
    private func showPullRequest(_ pr: PullRequest) {
        guard let repositoryURL else { return }
        statusLabel.stringValue = "拉取 PR #\(pr.number)…"

        diffTask?.cancel()
        diffTask = Task { [weak self] in
            guard let self else { return }
            do {
                let refs = try await self.engine.fetchPullRequest(
                    in: repositoryURL, number: pr.number, baseRef: pr.baseRef
                )
                guard !Task.isCancelled else { return }

                let document = try await self.engine.diff(
                    in: repositoryURL,
                    base: refs.base,
                    head: refs.head,
                    mode: .threeDot
                )
                guard !Task.isCancelled else { return }

                self.enterPullRequestMode(pr: pr, base: refs.base, head: refs.head)
                self.selectedCommitSHA = nil
                self.diffList.document = document
                self.sidebar.document = document
                self.sidebar.showFilesTab()
                self.statusLabel.stringValue =
                    "\(document.files.count) 个文件 · +\(document.totalAdditions) −\(document.totalDeletions)"
                                self.window?.title = "GitScope — PR #\(pr.number) \(pr.title)"
                // Populate the commit timeline for the PR range too.
                self.reloadCommits(base: refs.base, head: refs.head)
                // Fetch PR review comments.
                self.fetchPRComments(pr: pr)
            } catch is CancellationError {
            } catch {
                self.statusLabel.stringValue = "PR 拉取失败"
                self.showErrorAlert(error)
            }
        }
    }

    /// Switches the sidebar into PR mode: banner on, branch pickers off —
    /// one source of truth for what the diff shows.
    private func enterPullRequestMode(pr: PullRequest, base: String, head: String) {
        activePullRequest = (pr, base, head)
        prTitleLabel.stringValue = "PR #\(pr.number) \(pr.title)"
        prRefsLabel.stringValue = "\(pr.headRef) → \(pr.baseRef)"
        prBanner.isHidden = false
        // Hide toolbar branch controls in PR mode.
        basePopup.isHidden = true
        headPopup.isHidden = true
        modePopup.isHidden = true
        diffList.showsReviewButtons = true
        // Set persistence key for review progress.
        if let slug = GitHubClient.repoSlug(fromRemoteURL: repoRemoteURL ?? "") {
            sidebar.reviewPersistenceKey = "\(slug)/\(pr.number)"
        }
    }
    @objc private func exitPullRequestMode() {
        activePullRequest = nil
        prBanner.isHidden = true
        // Restore toolbar branch controls.
        basePopup.isHidden = false
        headPopup.isHidden = false
        modePopup.isHidden = false
        diffList.showsReviewButtons = false
        diffList.inlineComments = []
        sidebar.showFilesTab()
        // Keep persisted review data but disconnect the key so normal diffs don't save.
        sidebar.reviewPersistenceKey = nil
        updateWindowTitle()
        selectedCommitSHA = nil
        refreshDiff()
    }

    // MARK: PR Comments

    private func fetchPRComments(pr: PullRequest) {
        guard let repositoryURL,
              let slug = GitHubClient.repoSlug(fromRemoteURL: repoRemoteURL ?? "")
        else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                let reviewComments = try await self.gitHubClient.reviewComments(slug: slug, prNumber: pr.number)
                let issueComments = try await self.gitHubClient.issueComments(slug: slug, prNumber: pr.number)
                guard !Task.isCancelled else { return }
                // Map to InlineComment.
                let inline: [InlineComment] = reviewComments.compactMap { c in
                    InlineComment(
                        id: c.id, author: c.author, body: c.body,
                        createdAt: c.createdAt, avatarURL: c.avatarURL,
                        path: c.path, line: c.line ?? 0,
                        isReply: c.inReplyToId != nil
                    )
                }
                let general: [InlineComment] = issueComments.map { c in
                    InlineComment(
                        id: c.id, author: c.author, body: c.body,
                        createdAt: c.createdAt, avatarURL: c.avatarURL,
                        path: "", line: 0, isReply: false
                    )
                }
                let all = inline + general
                self.diffList.inlineComments = inline
                self.commentsPanel.update(comments: all)
                if !all.isEmpty {
                    self.sidebar.showCommentsTab()
                }
            } catch {
                // Silently ignore comment fetch failures.
            }
        }
    }

    private func jumpToComment(_ comment: InlineComment) {
        // Find the row in the diff that corresponds to this comment's file + line.
        guard let document = diffList.document else { return }
        for (fileIndex, file) in document.files.enumerated() {
            guard file.canonicalPath == comment.path else { continue }
            // Find the table row for this file's line.
            for (rowIndex, row) in diffList.currentRows.enumerated() {
                switch row {
                case .line(let f, let h, let l) where f == fileIndex:
                    let diffLine = document.files[f].hunks[h].lines[l]
                    if diffLine.newLineNumber == comment.line {
                        diffList.scrollToRow(rowIndex)
                        return
                    }
                default:
                    continue
                }
            }
            break
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

    /// Current number of context lines for the diff.
    private var contextLines: Int = 3

    private func refreshDiff() {
        guard let repositoryURL else { return }

        // In PR mode the comparison is pinned to the fetched PR refs; in
        // branch mode it follows the pickers.
        let base: String
        let head: String
        let mode: ComparisonMode
        if let active = activePullRequest {
            base = active.base
            head = active.head
            mode = .threeDot
        } else {
            guard let pickedBase = basePopup.titleOfSelectedItem,
                  let pickedHead = headPopup.titleOfSelectedItem
            else { return }
            base = pickedBase
            head = pickedHead
            mode = modePopup.indexOfSelectedItem == 0 ? .threeDot : .twoDot
        }
                let commitSHA = selectedCommitSHA

        // Set persistence key for review progress in normal branch mode.
        if activePullRequest == nil {
            if let slug = GitHubClient.repoSlug(fromRemoteURL: repoRemoteURL ?? "") {
                sidebar.reviewPersistenceKey = "\(slug)/\(base)..\(head)"
            }
            // Enable review buttons in normal diff mode too.
            diffList.showsReviewButtons = true
        }

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
                        in: repositoryURL, base: base, head: head, mode: mode,
                        contextLines: self.contextLines
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
