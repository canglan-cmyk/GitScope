import AppKit
import DiffRenderKit
import GitEngine

/// Right-side docked comments panel for PR review comments.
///
/// Layout, top to bottom:
///   [标题 "评论" + 关闭按钮]
///   [评论计数]
///   [分隔线]
///   [评论列表 — NSOutlineView, 按文件分组]
@MainActor
final class CommentsPanel: NSView {

    // MARK: Model

    private final class FileGroup {
        let path: String
        var comments: [InlineComment] = []
        init(path: String) { self.path = path }
    }

    private var groups: [FileGroup] = []
    private var generalComments: [InlineComment] = [] // issue-level (no file)

    // MARK: Callbacks

    /// Called when the user clicks a comment to jump to its location.
    var onSelectComment: ((InlineComment) -> Void)?
    /// Called when the user clicks the close button.
    var onClose: (() -> Void)?

    // MARK: UI

    private let titleLabel: NSTextField = {
        let f = NSTextField(labelWithString: "评论")
        f.font = .systemFont(ofSize: 13, weight: .semibold)
        f.translatesAutoresizingMaskIntoConstraints = false
        return f
    }()

    private let closeButton: NSButton = {
        let btn = NSButton(
            image: NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "关闭")!,
            target: nil, action: nil
        )
        btn.isBordered = false
        btn.translatesAutoresizingMaskIntoConstraints = false
        return btn
    }()

    private let countLabel: NSTextField = {
        let f = NSTextField(labelWithString: "")
        f.font = .systemFont(ofSize: 12)
        f.textColor = .secondaryLabelColor
        f.translatesAutoresizingMaskIntoConstraints = false
        return f
    }()

    private let separator: NSBox = {
        let box = NSBox()
        box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        return box
    }()

    private let scrollView: NSScrollView = {
        let sv = NSScrollView()
        sv.hasVerticalScroller = true
        sv.drawsBackground = false
        sv.translatesAutoresizingMaskIntoConstraints = false
        return sv
    }()

    private let outlineView: NSOutlineView = {
        let ov = NSOutlineView()
        ov.headerView = nil
        ov.indentationPerLevel = 0
        ov.rowSizeStyle = .custom
        ov.selectionHighlightStyle = .sourceList
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("comment"))
        col.isEditable = false
        ov.addTableColumn(col)
        ov.outlineTableColumn = col
        return ov
    }()

    private let emptyLabel: NSTextField = {
        let f = NSTextField(labelWithString: "暂无评论")
        f.font = .systemFont(ofSize: 12)
        f.textColor = .tertiaryLabelColor
        f.alignment = .center
        f.translatesAutoresizingMaskIntoConstraints = false
        return f
    }()

    // MARK: Init

    override init(frame: NSRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        wantsLayer = true

        closeButton.target = self
        closeButton.action = #selector(closeTapped)

        addSubview(titleLabel)
        addSubview(closeButton)
        addSubview(countLabel)
        addSubview(separator)
        addSubview(scrollView)
        addSubview(emptyLabel)

        scrollView.documentView = outlineView
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.doubleAction = #selector(rowDoubleClicked)
        outlineView.target = self

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),

            closeButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            closeButton.widthAnchor.constraint(equalToConstant: 20),
            closeButton.heightAnchor.constraint(equalToConstant: 20),

            countLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            countLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            countLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),

            separator.topAnchor.constraint(equalTo: countLabel.bottomAnchor, constant: 8),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),

            scrollView.topAnchor.constraint(equalTo: separator.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 32),
        ])
    }

    // MARK: Public API

    func update(comments: [InlineComment]) {
        // Separate inline vs general comments.
        generalComments = comments.filter { $0.path.isEmpty || $0.line <= 0 }
        let inlineComments = comments.filter { !$0.path.isEmpty && $0.line > 0 }

        // Group by file path.
        var groupMap: [String: FileGroup] = [:]
        var orderedPaths: [String] = []
        for comment in inlineComments {
            if groupMap[comment.path] == nil {
                groupMap[comment.path] = FileGroup(path: comment.path)
                orderedPaths.append(comment.path)
            }
            groupMap[comment.path]!.comments.append(comment)
        }
        groups = orderedPaths.compactMap { groupMap[$0] }

        let total = comments.count
        countLabel.stringValue = "\(total) 条评论" + (groups.isEmpty ? "" : "，位于 \(groups.count) 个文件")
        emptyLabel.isHidden = total > 0
        scrollView.isHidden = total == 0

        outlineView.reloadData()
        outlineView.expandItem(nil, expandChildren: true)
    }

    // MARK: Actions

    @objc private func closeTapped() {
        onClose?()
    }

    @objc private func rowDoubleClicked() {
        let row = outlineView.clickedRow
        guard row >= 0 else { return }
        let item = outlineView.item(atRow: row)
        if let comment = item as? InlineComment {
            onSelectComment?(comment)
        }
    }
}

// MARK: - NSOutlineViewDataSource

extension CommentsPanel: NSOutlineViewDataSource {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil {
            return groups.count + (generalComments.isEmpty ? 0 : 1)
        }
        if let group = item as? FileGroup {
            return group.comments.count
        }
        if item is String { // "General" group
            return generalComments.count
        }
        return 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil {
            if !generalComments.isEmpty && index == 0 {
                return "general" as NSString
            }
            let offset = generalComments.isEmpty ? 0 : 1
            return groups[index - offset]
        }
        if let group = item as? FileGroup {
            return group.comments[index]
        }
        if item is String {
            return generalComments[index]
        }
        return ""
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        return item is FileGroup || item is NSString
    }
}

// MARK: - NSOutlineViewDelegate

extension CommentsPanel: NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        if item is FileGroup || item is NSString { return 28 }
        return 52
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        if let group = item as? FileGroup {
            return makeFileHeaderCell(path: group.path, count: group.comments.count)
        }
        if item is NSString {
            return makeFileHeaderCell(path: "一般评论", count: generalComments.count)
        }
        if let comment = item as? InlineComment {
            return makeCommentCell(comment: comment)
        }
        return nil
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        return item is InlineComment
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        let row = outlineView.selectedRow
        guard row >= 0, let comment = outlineView.item(atRow: row) as? InlineComment else { return }
        onSelectComment?(comment)
    }

    // MARK: Cell factories

    private func makeFileHeaderCell(path: String, count: Int) -> NSView {
        let cell = NSTableCellView()
        let label = NSTextField(labelWithString: "")
        label.translatesAutoresizingMaskIntoConstraints = false

        let fileName = (path as NSString).lastPathComponent
        let dir = (path as NSString).deletingLastPathComponent

        let attributed = NSMutableAttributedString()
        attributed.append(NSAttributedString(
            string: fileName,
            attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold)]
        ))
        if !dir.isEmpty {
            attributed.append(NSAttributedString(
                string: "  \(dir.replacingOccurrences(of: "/", with: " › "))",
                attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]
            ))
        }
        attributed.append(NSAttributedString(
            string: "  (\(count))",
            attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.tertiaryLabelColor]
        ))
        label.attributedStringValue = attributed
        label.lineBreakMode = .byTruncatingTail

        cell.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    private func makeCommentCell(comment: InlineComment) -> NSView {
        let cell = NSTableCellView()

        // Author + time line.
        let headerLabel = NSTextField(labelWithString: "")
        headerLabel.translatesAutoresizingMaskIntoConstraints = false
        let header = NSMutableAttributedString()
        header.append(NSAttributedString(
            string: comment.author,
            attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .semibold)]
        ))
        header.append(NSAttributedString(
            string: "  \(comment.relativeTime)",
            attributes: [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.secondaryLabelColor]
        ))
        if let line = Optional(comment.line), line > 0 {
            header.append(NSAttributedString(
                string: "  L\(line)",
                attributes: [.font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular), .foregroundColor: NSColor.tertiaryLabelColor]
            ))
        }
        headerLabel.attributedStringValue = header

        // Body line.
        let bodyLabel = NSTextField(labelWithString: "")
        bodyLabel.translatesAutoresizingMaskIntoConstraints = false
        bodyLabel.font = .systemFont(ofSize: 11)
        bodyLabel.textColor = .labelColor
        bodyLabel.lineBreakMode = .byTruncatingTail
        bodyLabel.maximumNumberOfLines = 2
        bodyLabel.stringValue = comment.body.replacingOccurrences(of: "\n", with: " ")

        cell.addSubview(headerLabel)
        cell.addSubview(bodyLabel)
        NSLayoutConstraint.activate([
            headerLabel.topAnchor.constraint(equalTo: cell.topAnchor, constant: 4),
            headerLabel.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 12),
            headerLabel.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),

            bodyLabel.topAnchor.constraint(equalTo: headerLabel.bottomAnchor, constant: 2),
            bodyLabel.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 12),
            bodyLabel.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
        ])
        return cell
    }
}
