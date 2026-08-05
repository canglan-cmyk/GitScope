import AppKit
import DiffCore

// MARK: - Tree model

/// A node in the changed-files tree: a category group, a directory, or a
/// file leaf pointing back to its index in `DiffDocument.files`.
@MainActor
final class FileTreeNode {
    enum Kind {
        case category(ChangeCategory)
        case directory
        case file
    }

    let kind: Kind
    let name: String
    /// Index into `DiffDocument.files` for leaves; nil otherwise.
    let fileIndex: Int?
    let additions: Int
    let deletions: Int
    let change: FileChange?
    var children: [FileTreeNode] = []

    var isDirectory: Bool {
        if case .file = kind { return false }
        return true
    }

    var isCategory: Bool {
        if case .category = kind { return true }
        return false
    }

    var category: ChangeCategory? {
        if case .category(let c) = kind { return c }
        return nil
    }

    init(
        kind: Kind,
        name: String,
        fileIndex: Int? = nil,
        additions: Int = 0,
        deletions: Int = 0,
        change: FileChange? = nil
    ) {
        self.kind = kind
        self.name = name
        self.fileIndex = fileIndex
        self.additions = additions
        self.deletions = deletions
        self.change = change
    }

    /// Builds the sidebar tree: top level is change categories (core code
    /// first), inside each category a directory tree with single-child
    /// chains collapsed, files ordered by churn (protagonists first).
    ///
    /// `filter` (case-insensitive substring on the full path) prunes files.
    static func buildTree(from document: DiffDocument, filter: String = "") -> [FileTreeNode] {
        let needle = filter.trimmingCharacters(in: .whitespaces).lowercased()

        // Bucket files by category.
        var buckets: [ChangeCategory: [(Int, FileDiff)]] = [:]
        for (index, file) in document.files.enumerated() {
            if !needle.isEmpty, !file.canonicalPath.lowercased().contains(needle) {
                continue
            }
            let category = ChangeClassifier.classify(path: file.canonicalPath)
            buckets[category, default: []].append((index, file))
        }

        var roots: [FileTreeNode] = []
        for category in ChangeCategory.allCases.sorted(by: { $0.sortOrder < $1.sortOrder }) {
            guard let entries = buckets[category], !entries.isEmpty else { continue }

            let additions = entries.reduce(0) { $0 + $1.1.additionCount }
            let deletions = entries.reduce(0) { $0 + $1.1.deletionCount }
            let group = FileTreeNode(
                kind: .category(category),
                name: "\(category.displayNameKey) (\(entries.count))",
                additions: additions,
                deletions: deletions
            )

            // Build a directory tree inside the category.
            let dirRoot = FileTreeNode(kind: .directory, name: "")
            for (index, file) in entries {
                let components = file.canonicalPath.split(separator: "/").map(String.init)
                var current = dirRoot
                for (depth, component) in components.enumerated() {
                    let isLeaf = depth == components.count - 1
                    if isLeaf {
                        current.children.append(FileTreeNode(
                            kind: .file,
                            name: component,
                            fileIndex: index,
                            additions: file.additionCount,
                            deletions: file.deletionCount,
                            change: file.change
                        ))
                    } else {
                        if let existing = current.children.last(where: {
                            $0.isDirectory && !$0.isCategory && $0.name == component
                        }) {
                            current = existing
                        } else {
                            let dir = FileTreeNode(kind: .directory, name: component)
                            current.children.append(dir)
                            current = dir
                        }
                    }
                }
            }
            collapseChains(dirRoot)
            sortTree(dirRoot)
            group.children = dirRoot.children
            roots.append(group)
        }
        return roots
    }

    /// Merges single-child directory chains: `a → b → file` becomes `a/b → file`.
    private static func collapseChains(_ node: FileTreeNode) {
        for (index, child) in node.children.enumerated() where child.isDirectory {
            var merged = child
            while merged.children.count == 1,
                  let only = merged.children.first, only.isDirectory {
                let combined = FileTreeNode(kind: .directory, name: "\(merged.name)/\(only.name)")
                combined.children = only.children
                merged = combined
            }
            node.children[index] = merged
            collapseChains(merged)
        }
    }

    /// Directories first (alphabetical), then files by churn descending —
    /// protagonists first.
    private static func sortTree(_ node: FileTreeNode) {
        node.children.sort { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            if a.isDirectory {
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
            let churnA = a.additions + a.deletions
            let churnB = b.additions + b.deletions
            if churnA != churnB { return churnA > churnB }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        for child in node.children where child.isDirectory {
            sortTree(child)
        }
    }
}

// MARK: - Sidebar view controller

/// Sidebar: compare controls on top, a filename filter, then the changed
/// files grouped by category with review read-marks.
@MainActor
final class FileTreeSidebarController: NSViewController,
    NSOutlineViewDataSource, NSOutlineViewDelegate, NSSearchFieldDelegate, NSMenuDelegate {

    /// Called when the user picks a file (index into document.files).
    var onSelectFile: ((Int) -> Void)?
    /// Called when the user toggles the reviewed mark for a file index.
    var onToggleReviewed: ((Int) -> Void)?
    /// Called when the user asks to open a file in the external editor.
    var onOpenInEditor: ((Int) -> Void)?

    // MARK: Review persistence

    /// A key identifying the current comparison (e.g. repo slug + PR number) for persisting review state.
    var reviewPersistenceKey: String? {
        didSet {
            if let key = reviewPersistenceKey {
                let saved = UserDefaults.standard.stringArray(forKey: "ReviewedFiles.\(key)") ?? []
                reviewedFiles = Set(saved)
                updateReviewedSummary()
                outlineView.reloadData()
                restoreExpansion()
            }
        }
    }

    private func saveReviewedFiles() {
        guard let key = reviewPersistenceKey else { return }
        UserDefaults.standard.set(Array(reviewedFiles), forKey: "ReviewedFiles.\(key)")
    }

    /// Clears persisted review state for the current key.
    func clearPersistedReviewState() {
        guard let key = reviewPersistenceKey else { return }
        UserDefaults.standard.removeObject(forKey: "ReviewedFiles.\(key)")
        reviewPersistenceKey = nil
    }

    var document: DiffDocument? {
        didSet {
            // Only clear reviewed files if there's no persistence key (non-PR mode).
            if reviewPersistenceKey == nil {
                reviewedFiles.removeAll()
            }
            rebuildTree()
        }
    }

    /// Paths marked as reviewed (keyed by canonical path so marks survive
    /// re-diffs of the same comparison).
    private(set) var reviewedFiles: Set<String> = []

    func isReviewed(fileIndex: Int) -> Bool {
        guard let document, document.files.indices.contains(fileIndex) else { return false }
        return reviewedFiles.contains(document.files[fileIndex].canonicalPath)
    }

    func toggleReviewed(fileIndex: Int) {
        guard let document, document.files.indices.contains(fileIndex) else { return }
        let path = document.files[fileIndex].canonicalPath
        if reviewedFiles.contains(path) {
            reviewedFiles.remove(path)
        } else {
            reviewedFiles.insert(path)
        }
        saveReviewedFiles()
        updateReviewedSummary()
        outlineView.reloadData()
        restoreExpansion()
    }

    /// The controls stack the main controller installs its popups into.
    let controlsStack = NSStackView()

    /// The pull-request browser hosted in the sidebar's PR tab.
    let pullRequestPanel = PullRequestPanelController()

    private var treeRoots: [FileTreeNode] = []
    private let outlineView = NSOutlineView()
    private let scrollView = NSScrollView()
    private let filterField = NSSearchField()
    private let reviewedSummaryLabel = NSTextField(labelWithString: "")
    private let tabControl = NSSegmentedControl(
        labels: ["文件", "搜索", "评论", "PR"], trackingMode: .selectOne, target: nil, action: nil
    )
    // PR banner (set by MainWindowController, shown above tabs in PR mode).
    var prBannerView: NSView? {
        didSet {
            guard let v = prBannerView else { return }
            v.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(v)
            NSLayoutConstraint.activate([
                v.topAnchor.constraint(equalTo: view.topAnchor, constant: 4),
                v.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
                v.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            ])
            // Move tabControl below the banner when banner is visible.
            tabTopConstraint?.isActive = false
            tabTopConstraint = tabControl.topAnchor.constraint(equalTo: v.bottomAnchor, constant: 6)
            tabTopConstraint?.isActive = true
        }
    }
    private var tabTopConstraint: NSLayoutConstraint?
    // Containers for search and comments content (set by MainWindowController).
    var searchContentView: NSView? {
        didSet {
            guard let v = searchContentView else { return }
            v.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(v)
            v.isHidden = true
            NSLayoutConstraint.activate([
                v.topAnchor.constraint(equalTo: tabControl.bottomAnchor, constant: 6),
                v.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                v.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                v.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            ])
        }
    }
    var commentsContentView: NSView? {
        didSet {
            guard let v = commentsContentView else { return }
            v.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(v)
            v.isHidden = true
            NSLayoutConstraint.activate([
                v.topAnchor.constraint(equalTo: tabControl.bottomAnchor, constant: 6),
                v.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                v.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                v.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            ])
        }
    }

    private func rebuildTree() {
        treeRoots = document.map {
            FileTreeNode.buildTree(from: $0, filter: filterField.stringValue)
        } ?? []
        outlineView.reloadData()
        restoreExpansion()
        updateReviewedSummary()
    }

    private func restoreExpansion() {
        // Expand everything except noise categories (unless filtering).
        let filtering = !filterField.stringValue.isEmpty
        for root in treeRoots {
            if filtering || !(root.category?.collapsedByDefault ?? false) {
                outlineView.expandItem(root, expandChildren: true)
            }
        }
    }

    private func updateReviewedSummary() {
        guard let document, !document.files.isEmpty else {
            reviewedSummaryLabel.stringValue = ""
            return
        }
        let reviewed = document.files.filter { reviewedFiles.contains($0.canonicalPath) }.count
        reviewedSummaryLabel.stringValue = "已看 \(reviewed)/\(document.files.count)"
    }

    override func loadView() {
        let container = NSView()


        filterField.placeholderString = "过滤文件名"
        filterField.controlSize = .small
        filterField.delegate = self
        filterField.sendsSearchStringImmediately = true

        reviewedSummaryLabel.font = .systemFont(ofSize: 10)
        reviewedSummaryLabel.textColor = .secondaryLabelColor

        let column = NSOutlineColumn()
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.rowSizeStyle = .default
        outlineView.style = .sourceList
        outlineView.floatsGroupRows = false
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.target = self
        outlineView.action = #selector(rowClicked)
        outlineView.autoresizesOutlineColumn = true
        outlineView.indentationPerLevel = 12
        outlineView.allowsMultipleSelection = true
        outlineView.menu = makeContextMenu()

        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false


        tabControl.selectedSegment = 0
        tabControl.target = self
        tabControl.action = #selector(tabChanged)
        tabControl.controlSize = .mini
        tabControl.segmentDistribution = .fillEqually

        let filterRow = NSStackView(views: [filterField, reviewedSummaryLabel])
        filterRow.orientation = .horizontal
        filterRow.spacing = 6
        filterRow.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)

        addChild(pullRequestPanel)
        let prView = pullRequestPanel.view
        prView.isHidden = true

        for view in [tabControl, filterRow, scrollView, prView] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
        }
        tabTopConstraint = tabControl.topAnchor.constraint(equalTo: container.topAnchor, constant: 0)
        NSLayoutConstraint.activate([
            tabTopConstraint!,
            tabControl.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            tabControl.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),

            filterRow.topAnchor.constraint(equalTo: tabControl.bottomAnchor, constant: 6),
            filterRow.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            filterRow.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            scrollView.topAnchor.constraint(equalTo: filterRow.bottomAnchor, constant: 4),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            prView.topAnchor.constraint(equalTo: tabControl.bottomAnchor, constant: 8),
            prView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            prView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            prView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        view = container
    }

    @objc private func tabChanged() {
        let seg = tabControl.selectedSegment
        // Hide all content areas first.
        scrollView.isHidden = true
        filterField.isHidden = true
        reviewedSummaryLabel.isHidden = true
        pullRequestPanel.view.isHidden = true
        searchContentView?.isHidden = true
        commentsContentView?.isHidden = true
        // Show the selected tab's content.
        switch seg {
        case 0: // Files
            scrollView.isHidden = false
            filterField.isHidden = false
            reviewedSummaryLabel.isHidden = false
        case 1: // Search
            searchContentView?.isHidden = false
        case 2: // Comments
            commentsContentView?.isHidden = false
        case 3: // PR
            pullRequestPanel.view.isHidden = false
        default:
            break
        }
    }

    /// Switches the sidebar back to the files tab (after a PR diff loads).
    func showFilesTab() {
        tabControl.selectedSegment = 0
        tabChanged()
    }
    /// Switches to the search tab.
    func showSearchTab() {
        tabControl.selectedSegment = 1
        tabChanged()
    }
    /// Switches to the comments tab.
    func showCommentsTab() {
        tabControl.selectedSegment = 2
        tabChanged()
    }

    // MARK: Context menu

    private func makeContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        let markReviewed = NSMenuItem(
            title: "标记为已看",
            action: #selector(contextMarkReviewed),
            keyEquivalent: ""
        )
        markReviewed.target = self
        menu.addItem(markReviewed)

        let markUnreviewed = NSMenuItem(
            title: "标记为未看",
            action: #selector(contextMarkUnreviewed),
            keyEquivalent: ""
        )
        markUnreviewed.target = self
        menu.addItem(markUnreviewed)

        menu.addItem(.separator())

        let editorItem = NSMenuItem(
            title: "在编辑器中打开",
            action: #selector(contextOpenInEditor),
            keyEquivalent: ""
        )
        editorItem.target = self
        menu.addItem(editorItem)
        return menu
    }

    /// Collects all file indices from the current selection or clicked item.
    /// Supports files, folders (recursively), and multi-selection.
    private func fileIndicesForContextAction() -> [Int] {
        var indices: [Int] = []
        let selectedRows = outlineView.selectedRowIndexes
        let clickedRow = outlineView.clickedRow

        // If clicked row is in the selection, use the entire selection.
        // Otherwise, use only the clicked row.
        let rowsToProcess: IndexSet
        if clickedRow >= 0, selectedRows.contains(clickedRow), selectedRows.count > 1 {
            rowsToProcess = selectedRows
        } else if clickedRow >= 0 {
            rowsToProcess = IndexSet(integer: clickedRow)
        } else {
            rowsToProcess = selectedRows
        }

        for row in rowsToProcess {
            guard let node = outlineView.item(atRow: row) as? FileTreeNode else { continue }
            indices.append(contentsOf: collectFileIndices(from: node))
        }
        return Array(Set(indices)) // Deduplicate.
    }

    /// Recursively collects all file indices from a node (file or folder).
    private func collectFileIndices(from node: FileTreeNode) -> [Int] {
        if let fileIndex = node.fileIndex {
            return [fileIndex]
        }
        // Directory or category: recurse into children.
        var result: [Int] = []
        for child in node.children {
            result.append(contentsOf: collectFileIndices(from: child))
        }
        return result
    }

    @objc private func contextMarkReviewed() {
        let indices = fileIndicesForContextAction()
        for fileIndex in indices {
            markReviewed(fileIndex: fileIndex, reviewed: true)
        }
        finishBatchMark()
    }

    @objc private func contextMarkUnreviewed() {
        let indices = fileIndicesForContextAction()
        for fileIndex in indices {
            markReviewed(fileIndex: fileIndex, reviewed: false)
        }
        finishBatchMark()
    }

    /// Marks a file as reviewed or unreviewed without toggling.
    private func markReviewed(fileIndex: Int, reviewed: Bool) {
        guard let document, document.files.indices.contains(fileIndex) else { return }
        let path = document.files[fileIndex].canonicalPath
        if reviewed {
            reviewedFiles.insert(path)
        } else {
            reviewedFiles.remove(path)
        }
        onToggleReviewed?(fileIndex)
    }

    /// Called after batch mark operations to persist and refresh UI.
    private func finishBatchMark() {
        saveReviewedFiles()
        updateReviewedSummary()
        outlineView.reloadData()
        restoreExpansion()
    }

    @objc private func contextOpenInEditor() {
        let clickedRow = outlineView.clickedRow
        guard clickedRow >= 0,
              let node = outlineView.item(atRow: clickedRow) as? FileTreeNode,
              let fileIndex = node.fileIndex
        else { return }
        onOpenInEditor?(fileIndex)
    }

    // MARK: Actions

    @objc private func rowClicked() {
        let row = outlineView.clickedRow
        guard row >= 0,
              let node = outlineView.item(atRow: row) as? FileTreeNode
        else { return }
        if node.isDirectory {
            if outlineView.isItemExpanded(node) {
                outlineView.collapseItem(node)
            } else {
                outlineView.expandItem(node)
            }
        } else if let fileIndex = node.fileIndex {
            onSelectFile?(fileIndex)
        }
    }

    // MARK: NSSearchFieldDelegate

    func controlTextDidChange(_ obj: Notification) {
        guard (obj.object as? NSSearchField) === filterField else { return }
        rebuildTree()
    }

    // MARK: NSOutlineViewDataSource

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let node = item as? FileTreeNode else { return treeRoots.count }
        return node.children.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let node = item as? FileTreeNode else { return treeRoots[index] }
        return node.children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? FileTreeNode)?.isDirectory ?? false
    }

    // MARK: NSOutlineViewDelegate

    func outlineView(
        _ outlineView: NSOutlineView,
        viewFor tableColumn: NSTableColumn?,
        item: Any
    ) -> NSView? {
        guard let node = item as? FileTreeNode else { return nil }

        let identifier = NSUserInterfaceItemIdentifier("FileCell")
        let cell: FileTreeCellView
        if let reused = outlineView.makeView(withIdentifier: identifier, owner: self) as? FileTreeCellView {
            cell = reused
        } else {
            cell = FileTreeCellView()
            cell.identifier = identifier
        }
        let reviewed = node.fileIndex.map { isReviewed(fileIndex: $0) } ?? false
        cell.configure(node: node, reviewed: reviewed)
        return cell
    }
}

/// NSOutlineView requires a column; subclass only to have a stable type name.
private final class NSOutlineColumn: NSTableColumn {
    init() {
        super.init(identifier: NSUserInterfaceItemIdentifier("files"))
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

// MARK: - Cell

/// One row: icon + name + change stats (for files) / bold label (categories).
@MainActor
private final class FileTreeCellView: NSTableCellView {

    private let iconView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let statsLabel = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)

        nameLabel.font = .systemFont(ofSize: 12)
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        statsLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        statsLabel.setContentHuggingPriority(.required, for: .horizontal)
        statsLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        let stack = NSStackView(views: [iconView, nameLabel, statsLabel])
        stack.orientation = .horizontal
        stack.spacing = 5
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
        ])

        textField = nameLabel
        imageView = iconView
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(node: FileTreeNode, reviewed: Bool) {
        nameLabel.stringValue = node.name
        nameLabel.alphaValue = reviewed ? 0.45 : 1.0

        if node.isCategory {
            nameLabel.font = .systemFont(ofSize: 11, weight: .semibold)
            nameLabel.textColor = .secondaryLabelColor
            let symbol: String = switch node.category {
            case .core: "swift"
            case .tests: "checkmark.diamond"
            case .config: "gearshape"
            case .generated: "doc.badge.gearshape"
            case .docs: "doc.text"
            case .assets: "photo"
            case nil: "folder"
            }
            iconView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            iconView.contentTintColor = .secondaryLabelColor
            statsLabel.stringValue = ""
            return
        }

        nameLabel.font = .systemFont(ofSize: 12)
        nameLabel.textColor = .labelColor

        if node.isDirectory {
            iconView.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
            iconView.contentTintColor = .secondaryLabelColor
            statsLabel.stringValue = ""
            return
        }

        if reviewed {
            iconView.image = NSImage(
                systemSymbolName: "checkmark.circle.fill", accessibilityDescription: "已看"
            )
            iconView.contentTintColor = .systemGreen
        } else {
            let (symbol, tint): (String, NSColor) = switch node.change {
            case .added: ("plus.square.fill", .systemGreen)
            case .deleted: ("minus.square.fill", .systemRed)
            case .renamed: ("arrow.right.square.fill", .systemBlue)
            case .copied: ("doc.on.doc.fill", .systemBlue)
            default: ("square.fill", .systemOrange)
            }
            iconView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            iconView.contentTintColor = tint
        }

        let attributed = NSMutableAttributedString()
        if node.additions > 0 {
            attributed.append(NSAttributedString(
                string: "+\(node.additions)",
                attributes: [.foregroundColor: NSColor.systemGreen]
            ))
        }
        if node.deletions > 0 {
            if attributed.length > 0 {
                attributed.append(NSAttributedString(string: " "))
            }
            attributed.append(NSAttributedString(
                string: "−\(node.deletions)",
                attributes: [.foregroundColor: NSColor.systemRed]
            ))
        }
        statsLabel.attributedStringValue = attributed
    }
}
