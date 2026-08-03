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
    NSOutlineViewDataSource, NSOutlineViewDelegate, NSSearchFieldDelegate {

    /// Called when the user picks a file (index into document.files).
    var onSelectFile: ((Int) -> Void)?
    /// Called when the user toggles the reviewed mark for a file index.
    var onToggleReviewed: ((Int) -> Void)?
    /// Called when the user asks to open a file in the external editor.
    var onOpenInEditor: ((Int) -> Void)?

    var document: DiffDocument? {
        didSet {
            reviewedFiles.removeAll()
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
        labels: ["文件", "Pull Requests"], trackingMode: .selectOne, target: nil, action: nil
    )

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

        controlsStack.orientation = .vertical
        controlsStack.alignment = .leading
        controlsStack.spacing = 8
        controlsStack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)

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
        outlineView.menu = makeContextMenu()

        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false

        let separator = NSBox()
        separator.boxType = .separator

        tabControl.selectedSegment = 0
        tabControl.target = self
        tabControl.action = #selector(tabChanged)
        tabControl.controlSize = .small
        tabControl.segmentDistribution = .fillEqually

        let filterRow = NSStackView(views: [filterField, reviewedSummaryLabel])
        filterRow.orientation = .horizontal
        filterRow.spacing = 6
        filterRow.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)

        addChild(pullRequestPanel)
        let prView = pullRequestPanel.view
        prView.isHidden = true

        for view in [controlsStack, separator, tabControl, filterRow, scrollView, prView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
        }
        NSLayoutConstraint.activate([
            controlsStack.topAnchor.constraint(equalTo: container.topAnchor),
            controlsStack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            controlsStack.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            separator.topAnchor.constraint(equalTo: controlsStack.bottomAnchor),
            separator.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            tabControl.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 8),
            tabControl.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            tabControl.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),

            filterRow.topAnchor.constraint(equalTo: tabControl.bottomAnchor, constant: 8),
            filterRow.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            filterRow.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            scrollView.topAnchor.constraint(equalTo: filterRow.bottomAnchor, constant: 6),
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
        let showPRs = tabControl.selectedSegment == 1
        pullRequestPanel.view.isHidden = !showPRs
        scrollView.isHidden = showPRs
        filterField.isHidden = showPRs
        reviewedSummaryLabel.isHidden = showPRs
    }

    /// Switches the sidebar back to the files tab (after a PR diff loads).
    func showFilesTab() {
        tabControl.selectedSegment = 0
        tabChanged()
    }

    // MARK: Context menu

    private func makeContextMenu() -> NSMenu {
        let menu = NSMenu()
        let toggleItem = NSMenuItem(
            title: "标记为已看/未看",
            action: #selector(contextToggleReviewed),
            keyEquivalent: ""
        )
        toggleItem.target = self
        menu.addItem(toggleItem)

        let editorItem = NSMenuItem(
            title: "在编辑器中打开",
            action: #selector(contextOpenInEditor),
            keyEquivalent: ""
        )
        editorItem.target = self
        menu.addItem(editorItem)
        return menu
    }

    @objc private func contextToggleReviewed() {
        guard let node = clickedFileNode(), let fileIndex = node.fileIndex else { return }
        toggleReviewed(fileIndex: fileIndex)
        onToggleReviewed?(fileIndex)
    }

    @objc private func contextOpenInEditor() {
        guard let node = clickedFileNode(), let fileIndex = node.fileIndex else { return }
        onOpenInEditor?(fileIndex)
    }

    private func clickedFileNode() -> FileTreeNode? {
        let row = outlineView.clickedRow
        guard row >= 0,
              let node = outlineView.item(atRow: row) as? FileTreeNode,
              !node.isDirectory
        else { return nil }
        return node
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
