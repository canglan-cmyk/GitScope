import AppKit
import GitEngine

/// Sidebar-hosted pull request browser: Device Flow login, open-PR list for
/// the current repository's GitHub remote, and a jump-to-PR-diff callback.
/// The diff itself is computed locally after fetching `pull/{n}/head`.
@MainActor
final class PullRequestPanelController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {

    /// Called when the user picks a PR. The app fetches refs and shows the diff.
    var onSelectPullRequest: ((PullRequest) -> Void)?

    private let client = GitHubClient()
    private var pullRequests: [PullRequest] = []
    private var repoSlug: String?
    private var authTask: Task<Void, Never>?

    // UI
    private let statusLabel = NSTextField(labelWithString: "")
    private let loginButton = NSButton(title: "登录 GitHub…", target: nil, action: nil)
    private let refreshButton = NSButton(title: "刷新", target: nil, action: nil)
    private let codeField = NSTextField(labelWithString: "")
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()

    // MARK: Lifecycle

    override func loadView() {
        let container = NSView()

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.maximumNumberOfLines = 2

        loginButton.target = self
        loginButton.action = #selector(startLogin)
        loginButton.controlSize = .small
        loginButton.bezelStyle = .rounded

        refreshButton.target = self
        refreshButton.action = #selector(refresh)
        refreshButton.controlSize = .small
        refreshButton.bezelStyle = .rounded
        refreshButton.isHidden = true

        codeField.font = .monospacedSystemFont(ofSize: 18, weight: .bold)
        codeField.alignment = .center
        codeField.isSelectable = true
        codeField.isHidden = true

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("pr"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 44
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(rowClicked)
        tableView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        tableView.style = .sourceList

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false

        let buttonRow = NSStackView(views: [loginButton, refreshButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 6

        let stack = NSStackView(views: [buttonRow, codeField, statusLabel, scrollView])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.widthAnchor.constraint(equalTo: stack.widthAnchor),
            codeField.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        view = container
        updateAuthUI()
    }

    // MARK: Public API

    /// Points the panel at a repository; resolves the GitHub slug from its
    /// remote and loads PRs when authenticated.
    func setRepository(remoteURL: String?) {
        repoSlug = remoteURL.flatMap { GitHubClient.repoSlug(fromRemoteURL: $0) }
        pullRequests = []
        tableView.reloadData()
        if repoSlug == nil {
            statusLabel.stringValue = remoteURL == nil
                ? "该仓库没有远程地址"
                : "远程不是 GitHub 仓库"
        } else {
            statusLabel.stringValue = repoSlug ?? ""
            if client.isAuthenticated { loadPullRequests() }
        }
        updateAuthUI()
    }

    // MARK: Auth

    private func updateAuthUI() {
        let authed = client.isAuthenticated
        loginButton.title = authed ? "退出登录" : "登录 GitHub…"
        loginButton.action = authed ? #selector(logout) : #selector(startLogin)
        refreshButton.isHidden = !(authed && repoSlug != nil)
    }

    @objc private func startLogin() {
        authTask?.cancel()
        authTask = Task { [weak self] in
            guard let self else { return }
            do {
                self.statusLabel.stringValue = "正在获取授权码…"
                let session = try await self.client.startDeviceFlow()

                // Show the one-time code, copy it, and open the verify page.
                self.codeField.stringValue = session.userCode
                self.codeField.isHidden = false
                self.statusLabel.stringValue =
                    "已复制授权码并打开浏览器，粘贴授权码完成授权"
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(session.userCode, forType: .string)
                NSWorkspace.shared.open(session.verificationURL)

                _ = try await self.client.waitForAuthorization(session)
                self.codeField.isHidden = true
                let login = (try? await self.client.currentUser()) ?? ""
                self.statusLabel.stringValue = "已登录\(login.isEmpty ? "" : "：\(login)")"
                self.updateAuthUI()
                self.loadPullRequests()
            } catch is CancellationError {
            } catch {
                self.codeField.isHidden = true
                self.statusLabel.stringValue = error.localizedDescription
            }
        }
    }

    @objc private func logout() {
        authTask?.cancel()
        client.clearToken()
        pullRequests = []
        tableView.reloadData()
        statusLabel.stringValue = "已退出登录"
        updateAuthUI()
    }

    // MARK: PR list

    @objc private func refresh() {
        loadPullRequests()
    }

    private func loadPullRequests() {
        guard let repoSlug else { return }
        statusLabel.stringValue = "加载 PR 列表…"
        Task { [weak self] in
            guard let self else { return }
            do {
                let prs = try await self.client.openPullRequests(slug: repoSlug)
                self.pullRequests = prs
                self.tableView.reloadData()
                self.statusLabel.stringValue = prs.isEmpty
                    ? "\(repoSlug)：没有打开的 PR"
                    : "\(repoSlug)：\(prs.count) 个打开的 PR"
            } catch {
                self.statusLabel.stringValue = error.localizedDescription
            }
        }
    }

    @objc private func rowClicked() {
        let row = tableView.clickedRow >= 0 ? tableView.clickedRow : tableView.selectedRow
        guard pullRequests.indices.contains(row) else { return }
        onSelectPullRequest?(pullRequests[row])
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { pullRequests.count }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        let pr = pullRequests[row]

        let identifier = NSUserInterfaceItemIdentifier("PRCell")
        let cell: PullRequestCellView
        if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? PullRequestCellView {
            cell = reused
        } else {
            cell = PullRequestCellView()
            cell.identifier = identifier
        }
        cell.configure(pr: pr)
        return cell
    }
}

// MARK: - PR cell

@MainActor
private final class PullRequestCellView: NSTableCellView {

    private let titleLabel = NSTextField(labelWithString: "")
    private let metaLabel = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)

        titleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        titleLabel.lineBreakMode = .byTruncatingTail

        metaLabel.font = .systemFont(ofSize: 10)
        metaLabel.textColor = .secondaryLabelColor
        metaLabel.lineBreakMode = .byTruncatingTail

        let stack = NSStackView(views: [titleLabel, metaLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(pr: PullRequest) {
        let draft = pr.isDraft ? "[草稿] " : ""
        titleLabel.stringValue = "\(draft)#\(pr.number) \(pr.title)"
        metaLabel.stringValue = "\(pr.author) · \(pr.headRef) → \(pr.baseRef)"
    }
}
