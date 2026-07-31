import AppKit
import GitEngine

/// A lightweight results panel for repo-wide reference lookup: shows every
/// occurrence of an identifier, marking whether the file is part of the
/// current diff (in-diff = green, outside = yellow — the potential missed
/// call sites worth double-checking).
@MainActor
final class ReferencePanelController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {

    /// Jump callback: (repo-relative path, line number).
    var onJump: ((String, Int) -> Void)?
    /// Called when the user dismisses the panel.
    var onClose: (() -> Void)?

    private let symbolName: String
    private let references: [SymbolReference]
    private let tableView = NSTableView()

    init(identifier: String, references: [SymbolReference]) {
        self.symbolName = identifier
        self.references = references
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let inDiff = references.filter(\.isInDiff).count
        let outside = references.count - inDiff
        let header = NSTextField(labelWithString:
            "“\(symbolName)” 共 \(references.count) 处引用 · diff 内 \(inDiff) · diff 外 \(outside)"
        )
        header.font = .systemFont(ofSize: 12, weight: .semibold)
        header.lineBreakMode = .byTruncatingTail

        let hint = NSTextField(labelWithString: "⚠️ diff 外的引用可能是漏改的调用点；双击跳转到编辑器")
        hint.font = .systemFont(ofSize: 10)
        hint.textColor = .secondaryLabelColor

        let closeButton = NSButton(title: "关闭", target: self, action: #selector(closePanel))
        closeButton.bezelStyle = .rounded
        closeButton.keyEquivalent = "\u{1b}" // Esc

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("ref"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 36
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(rowDoubleClicked)
        tableView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true

        let stack = NSStackView(views: [header, hint, scrollView, closeButton])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
            container.widthAnchor.constraint(equalToConstant: 560),
            container.heightAnchor.constraint(equalToConstant: 420),
        ])
        view = container
    }

    @objc private func closePanel() {
        onClose?()
    }

    @objc private func rowDoubleClicked() {
        let row = tableView.clickedRow
        guard references.indices.contains(row) else { return }
        let reference = references[row]
        onJump?(reference.filePath, reference.lineNumber)
    }

    // MARK: Data source / delegate

    func numberOfRows(in tableView: NSTableView) -> Int { references.count }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        let reference = references[row]

        let identifier = NSUserInterfaceItemIdentifier("RefCell")
        let cell: ReferenceCellView
        if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? ReferenceCellView {
            cell = reused
        } else {
            cell = ReferenceCellView()
            cell.identifier = identifier
        }
        cell.configure(reference: reference)
        return cell
    }
}

@MainActor
private final class ReferenceCellView: NSTableCellView {

    private let badge = NSTextField(labelWithString: "")
    private let locationLabel = NSTextField(labelWithString: "")
    private let codeLabel = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)

        badge.font = .systemFont(ofSize: 9, weight: .semibold)
        badge.alignment = .center
        badge.wantsLayer = true
        badge.layer?.cornerRadius = 3
        badge.setContentHuggingPriority(.required, for: .horizontal)

        locationLabel.font = .systemFont(ofSize: 11, weight: .medium)
        locationLabel.lineBreakMode = .byTruncatingMiddle

        codeLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        codeLabel.textColor = .secondaryLabelColor
        codeLabel.lineBreakMode = .byTruncatingTail

        let topRow = NSStackView(views: [badge, locationLabel])
        topRow.orientation = .horizontal
        topRow.spacing = 6

        let stack = NSStackView(views: [topRow, codeLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            badge.widthAnchor.constraint(equalToConstant: 52),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(reference: SymbolReference) {
        if reference.isInDiff {
            badge.stringValue = "diff 内"
            badge.textColor = .white
            badge.layer?.backgroundColor = NSColor.systemGreen.cgColor
        } else {
            badge.stringValue = "diff 外"
            badge.textColor = .black
            badge.layer?.backgroundColor = NSColor.systemYellow.cgColor
        }
        locationLabel.stringValue = "\(reference.filePath):\(reference.lineNumber)"
        codeLabel.stringValue = reference.lineText
    }
}
