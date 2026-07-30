import AppKit
import DiffCore

// MARK: - Tree model

/// A node in the changed-files tree: either a directory (with children) or a
/// file leaf pointing back to its index in `DiffDocument.files`.
@MainActor
final class FileTreeNode {
    let name: String
    let isDirectory: Bool
    /// Index into `DiffDocument.files` for leaves; nil for directories.
    let fileIndex: Int?
    let additions: Int
    let deletions: Int
    let change: FileChange?
    var children: [FileTreeNode] = []

    init(
        name: String,
        isDirectory: Bool,
        fileIndex: Int? = nil,
        additions: Int = 0,
        deletions: Int = 0,
        change: FileChange? = nil
    ) {
        self.name = name
        self.isDirectory = isDirectory
        self.fileIndex = fileIndex
        self.additions = additions
        self.deletions = deletions
        self.change = change
    }

    /// Builds a directory tree from the document's file list, collapsing
    /// single-child directory chains (a/b/c → "a/b/c") like Xcode/GitHub.
    static func buildTree(from document: DiffDocument) -> [FileTreeNode] {
        let root = FileTreeNode(name: "", isDirectory: true)

        for (index, file) in document.files.enumerated() {
            let path = file.canonicalPath
            let components = path.split(separator: "/").map(String.init)
            var current = root
            for (depth, component) in components.enumerated() {
                let isLeaf = depth == components.count - 1
                if isLeaf {
                    current.children.append(FileTreeNode(
                        name: component,
                        isDirectory: false,
                        fileIndex: index,
                        additions: file.additionCount,
                        deletions: file.deletionCount,
                        change: file.change
                    ))
                } else {
                    if let existing = current.children.last(where: { $0.isDirectory && $0.name == component }) {
                        current = existing
                    } else {
                        let dir = FileTreeNode(name: component, isDirectory: true)
                        current.children.append(dir)
                        current = dir
                    }
                }
            }
        }

        collapseChains(root)
        sortTree(root)
        return root.children
    }

    /// Merges single-child directory chains: `a → b → file` becomes `a/b → file`.
    private static func collapseChains(_ node: FileTreeNode) {
        for (index, child) in node.children.enumerated() where child.isDirectory {
            var merged = child
            while merged.children.count == 1, let only = merged.children.first, only.isDirectory {
                let combined = FileTreeNode(name: "\(merged.name)/\(only.name)", isDirectory: true)
                combined.children = only.children
                merged = combined
            }
            node.children[index] = merged
            collapseChains(merged)
        }
    }

    /// Directories first, then files, both alphabetically.
    private static func sortTree(_ node: FileTreeNode) {
        node.children.sort { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        for child in node.children where child.isDirectory {
            sortTree(child)
        }
    }
}

// MARK: - Sidebar view controller

/// Sidebar: compare controls on top, changed-files outline below.
@MainActor
final class FileTreeSidebarController: NSViewController,
    NSOutlineViewDataSource, NSOutlineViewDelegate {

    /// Called when the user picks a file (index into document.files).
    var onSelectFile: ((Int) -> Void)?

    var document: DiffDocument? {
        didSet {
            treeRoots = document.map(FileTreeNode.buildTree(from:)) ?? []
            outlineView.reloadData()
            outlineView.expandItem(nil, expandChildren: true)
        }
    }

    /// The controls stack the main controller installs its popups into.
    let controlsStack = NSStackView()

    private var treeRoots: [FileTreeNode] = []
    private let outlineView = NSOutlineView()
    private let scrollView = NSScrollView()

    override func loadView() {
        let container = NSView()

        controlsStack.orientation = .vertical
        controlsStack.alignment = .leading
        controlsStack.spacing = 8
        controlsStack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)

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

        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false

        let separator = NSBox()
        separator.boxType = .separator

        for view in [controlsStack, separator, scrollView] {
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

            scrollView.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 4),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        view = container
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
        cell.configure(node: node)
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

/// One row: icon + name + change stats (for files).
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

    func configure(node: FileTreeNode) {
        nameLabel.stringValue = node.name

        if node.isDirectory {
            iconView.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
            iconView.contentTintColor = .secondaryLabelColor
            statsLabel.stringValue = ""
            return
        }

        let (symbol, tint): (String, NSColor) = switch node.change {
        case .added: ("plus.square.fill", .systemGreen)
        case .deleted: ("minus.square.fill", .systemRed)
        case .renamed: ("arrow.right.square.fill", .systemBlue)
        case .copied: ("doc.on.doc.fill", .systemBlue)
        default: ("square.fill", .systemOrange)
        }
        iconView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        iconView.contentTintColor = tint

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
