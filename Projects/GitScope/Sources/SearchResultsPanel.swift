import AppKit
import DiffRenderKit

/// Right-side docked search panel (Xcode find-navigator style).
///
/// Layout, top to bottom:
///   [搜索框 + 关闭按钮]
///   [范围切换 + 结果计数]
///   [分隔线]
///   [结果列表 — NSOutlineView,按文件分组,可折叠]
///
/// The panel owns the search field; MainWindowController shows/hides the
/// whole panel and forwards search state through `update`/`setCurrent`.
@MainActor
final class SearchResultsPanel: NSView {

    // MARK: Model

    private final class FileGroup {
        let path: String
        var items: [MatchItem] = []
        init(path: String) { self.path = path }
    }

    private final class MatchItem {
        let index: Int
        let lineNumber: Int?
        let preview: String
        let hit: Range<Int>
        init(index: Int, lineNumber: Int?, preview: String, hit: Range<Int>) {
            self.index = index
            self.lineNumber = lineNumber
            self.preview = preview
            self.hit = hit
        }
    }

    private var groups: [FileGroup] = []
    private var currentMatchIndex: Int = -1
    private var totalMatches: Int = 0

    // MARK: Callbacks

    var onSelectMatch: ((Int) -> Void)?
    var onClose: (() -> Void)?

    // MARK: Controls (exposed so the window controller can wire them)

    let searchField = NSSearchField()
    let scopeControl = NSSegmentedControl(
        labels: ["全部行", "仅变更行"], trackingMode: .selectOne, target: nil, action: nil
    )

    private let resultLabel = NSTextField(labelWithString: "")
    private let emptyLabel = NSTextField(labelWithString: "输入关键字开始搜索")
    private let outlineView = NSOutlineView()
    private let scrollView = NSScrollView()

    // MARK: Init

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        // Panel chrome: match the sidebar's material look.
        let material = NSVisualEffectView()
        material.material = .sidebar
        material.blendingMode = .behindWindow
        material.translatesAutoresizingMaskIntoConstraints = false
        addSubview(material)

        let leftBorder = NSBox()
        leftBorder.boxType = .separator
        leftBorder.translatesAutoresizingMaskIntoConstraints = false
        addSubview(leftBorder)

        // Header row: title + close.
        let titleLabel = NSTextField(labelWithString: "搜索")
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .secondaryLabelColor

        let closeButton = NSButton(
            image: NSImage(
                systemSymbolName: "xmark.circle.fill", accessibilityDescription: "关闭"
            )!,
            target: self, action: #selector(closeClicked)
        )
        closeButton.isBordered = false
        closeButton.contentTintColor = .tertiaryLabelColor

        let headerSpacer = NSView()
        headerSpacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let headerRow = NSStackView(views: [titleLabel, headerSpacer, closeButton])
        headerRow.orientation = .horizontal
        headerRow.spacing = 4

        // Search field.
        searchField.placeholderString = "在 diff 中搜索"
        searchField.controlSize = .regular
        searchField.sendsWholeSearchString = false

        // Scope + count row.
        scopeControl.selectedSegment = 0
        scopeControl.controlSize = .small

        resultLabel.font = .systemFont(ofSize: 12)
        resultLabel.textColor = .secondaryLabelColor
        resultLabel.alignment = .center

        let scopeRow = NSStackView(views: [scopeControl, resultLabel])
        scopeRow.orientation = .horizontal
        scopeRow.spacing = 8

        let header = NSStackView(views: [headerRow, searchField, scopeRow])
        header.orientation = .vertical
        header.alignment = .width
        header.distribution = .fill
        header.spacing = 8
        header.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        header.setHuggingPriority(.defaultLow, for: .horizontal)
        header.translatesAutoresizingMaskIntoConstraints = false
        addSubview(header)

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(separator)

        // Results list: source-list outline grouped by file.
        let column = NSTableColumn(identifier: .init("match"))
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.style = .sourceList
        outlineView.rowSizeStyle = .custom
        outlineView.indentationPerLevel = 8
        outlineView.floatsGroupRows = false
        outlineView.autoresizesOutlineColumn = false
        outlineView.intercellSpacing = NSSize(width: 0, height: 0)
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.target = self
        outlineView.action = #selector(rowClicked)

        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: 4, left: 0, bottom: 8, right: 0)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        emptyLabel.font = .systemFont(ofSize: 13)
        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            material.topAnchor.constraint(equalTo: topAnchor),
            material.bottomAnchor.constraint(equalTo: bottomAnchor),
            material.leadingAnchor.constraint(equalTo: leadingAnchor),
            material.trailingAnchor.constraint(equalTo: trailingAnchor),

            leftBorder.topAnchor.constraint(equalTo: topAnchor),
            leftBorder.bottomAnchor.constraint(equalTo: bottomAnchor),
            leftBorder.leadingAnchor.constraint(equalTo: leadingAnchor),
            leftBorder.widthAnchor.constraint(equalToConstant: 1),

            // NOTE: do not use safeAreaLayoutGuide here — inside a collapsed
            // NSSplitViewItem it binds to the window's content layout guide
            // with required priority and freezes window resizing.
            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 1),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),

            separator.topAnchor.constraint(equalTo: header.bottomAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 1),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),

            scrollView.topAnchor.constraint(equalTo: separator.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 1),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.topAnchor.constraint(equalTo: scrollView.topAnchor, constant: 32),
        ])

        // Keep the panel flexible in both axes so it never constrains the
        // window: content compresses/stretches with the split view.
        setContentHuggingPriority(.init(1), for: .vertical)
        setContentCompressionResistancePriority(.init(1), for: .vertical)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: Public API

    func update(matches: [DiffListViewController.SearchMatch], currentIndex: Int) {
        groups = []
        totalMatches = matches.count
        var groupByPath: [String: FileGroup] = [:]
        for (index, match) in matches.enumerated() {
            let group: FileGroup
            if let existing = groupByPath[match.filePath] {
                group = existing
            } else {
                group = FileGroup(path: match.filePath)
                groupByPath[match.filePath] = group
                groups.append(group)
            }
            group.items.append(MatchItem(
                index: index,
                lineNumber: match.lineNumber,
                preview: match.preview,
                hit: match.range
            ))
        }
        currentMatchIndex = currentIndex
        outlineView.reloadData()
        outlineView.expandItem(nil, expandChildren: true)
        refreshEmptyState(searchedButEmpty: matches.isEmpty && !searchField.stringValue.isEmpty)
        updateResultLabel()
        highlightCurrent(scroll: true)
    }

    func setCurrent(index: Int) {
        currentMatchIndex = index
        updateResultLabel()
        highlightCurrent(scroll: true)
    }

    func clear() {
        groups = []
        totalMatches = 0
        currentMatchIndex = -1
        outlineView.reloadData()
        refreshEmptyState(searchedButEmpty: false)
        updateResultLabel()
    }

    func focusSearchField() {
        window?.makeFirstResponder(searchField)
    }

    // MARK: Internals

    private func refreshEmptyState(searchedButEmpty: Bool) {
        if groups.isEmpty {
            emptyLabel.stringValue = searchedButEmpty ? "无结果" : "输入关键字开始搜索"
            emptyLabel.isHidden = false
        } else {
            emptyLabel.isHidden = true
        }
    }

    private func updateResultLabel() {
        if totalMatches == 0 {
            resultLabel.stringValue = ""
        } else {
            resultLabel.stringValue = "\(totalMatches) 个结果，位于 \(groups.count) 个文件"
        }
    }

    private func highlightCurrent(scroll: Bool) {
        guard currentMatchIndex >= 0 else {
            outlineView.deselectAll(nil)
            return
        }
        for group in groups {
            if let item = group.items.first(where: { $0.index == currentMatchIndex }) {
                outlineView.expandItem(group)
                let row = outlineView.row(forItem: item)
                guard row >= 0 else { return }
                outlineView.selectRowIndexes([row], byExtendingSelection: false)
                if scroll { outlineView.scrollRowToVisible(row) }
                return
            }
        }
    }

    @objc private func rowClicked() {
        let row = outlineView.clickedRow
        guard row >= 0 else { return }
        if let item = outlineView.item(atRow: row) as? MatchItem {
            onSelectMatch?(item.index)
        } else if let group = outlineView.item(atRow: row) as? FileGroup {
            // Toggle group expansion on click.
            if outlineView.isItemExpanded(group) {
                outlineView.collapseItem(group)
            } else {
                outlineView.expandItem(group)
            }
        }
    }

    @objc private func closeClicked() {
        onClose?()
    }
}

// MARK: - Outline data source / delegate

extension SearchResultsPanel: NSOutlineViewDataSource, NSOutlineViewDelegate {

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil { return groups.count }
        if let group = item as? FileGroup { return group.items.count }
        return 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil { return groups[index] }
        return (item as! FileGroup).items[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        item is FileGroup
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        item is FileGroup ? 40 : 22
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        item is MatchItem
    }

    func outlineView(
        _ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any
    ) -> NSView? {
        if let group = item as? FileGroup {
            let id = NSUserInterfaceItemIdentifier("fileGroup")
            let cell = outlineView.makeView(withIdentifier: id, owner: self)
                as? SearchFileCellView ?? {
                    let c = SearchFileCellView()
                    c.identifier = id
                    return c
                }()
            cell.configure(path: group.path, count: group.items.count)
            return cell
        }
        if let match = item as? MatchItem {
            let id = NSUserInterfaceItemIdentifier("matchRow")
            let cell = outlineView.makeView(withIdentifier: id, owner: self)
                as? SearchMatchCellView ?? {
                    let c = SearchMatchCellView()
                    c.identifier = id
                    return c
                }()
            cell.configure(
                preview: match.preview,
                hit: match.hit,
                isCurrent: match.index == currentMatchIndex
            )
            return cell
        }
        return nil
    }
}

// MARK: - File group cell

@MainActor
private final class SearchFileCellView: NSTableCellView {

    private let iconView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)

        iconView.image = NSImage(
            systemSymbolName: "doc.text.fill", accessibilityDescription: nil
        )
        iconView.symbolConfiguration = .init(pointSize: 12, weight: .regular)
        iconView.contentTintColor = .controlAccentColor
        iconView.setContentHuggingPriority(.required, for: .horizontal)

        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.allowsDefaultTighteningForTruncation = false

        let stack = NSStackView(views: [iconView, nameLabel])
        stack.orientation = .horizontal
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -6),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(path: String, count: Int) {
        // File-type icon based on extension.
        let ext = ((path as NSString).pathExtension).lowercased()
        let symbolName: String
        let tint: NSColor
        switch ext {
        case "swift":
            symbolName = "swift"; tint = .systemOrange
        case "h", "m", "mm", "c", "cpp", "cc":
            symbolName = "chevron.left.forwardslash.chevron.right"; tint = .systemBlue
        case "json":
            symbolName = "curlybraces"; tint = .systemYellow
        case "plist", "xml", "yaml", "yml":
            symbolName = "doc.badge.gearshape"; tint = .systemGray
        case "md", "txt", "rtf":
            symbolName = "doc.text"; tint = .secondaryLabelColor
        case "png", "jpg", "jpeg", "svg", "gif", "webp", "pdf":
            symbolName = "photo"; tint = .systemTeal
        case "js", "ts", "jsx", "tsx":
            symbolName = "j.square"; tint = .systemYellow
        case "py":
            symbolName = "p.square"; tint = .systemBlue
        case "rb":
            symbolName = "r.square"; tint = .systemRed
        case "css", "scss", "less":
            symbolName = "paintbrush"; tint = .systemPink
        case "html", "htm":
            symbolName = "globe"; tint = .systemBlue
        case "sh", "bash", "zsh":
            symbolName = "terminal"; tint = .systemGreen
        case "xcodeproj", "xcworkspace", "pbxproj":
            symbolName = "hammer"; tint = .systemBlue
        default:
            symbolName = "doc.text.fill"; tint = .controlAccentColor
        }
        iconView.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        iconView.contentTintColor = tint

        // Xcode style: bold file name on first line, dimmed directory path on second.
        let name = (path as NSString).lastPathComponent
        let dir = (path as NSString).deletingLastPathComponent
        let attributed = NSMutableAttributedString(
            string: name,
            attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                .foregroundColor: NSColor.labelColor,
            ]
        )
        if !dir.isEmpty {
            attributed.append(NSAttributedString(
                string: "\n" + dir.replacingOccurrences(of: "/", with: " › "),
                attributes: [
                    .font: NSFont.systemFont(ofSize: 11),
                    .foregroundColor: NSColor.tertiaryLabelColor,
                ]
            ))
        }
        nameLabel.attributedStringValue = attributed
        nameLabel.maximumNumberOfLines = 2
        toolTip = "\(path) — \(count) 个结果"
    }
}

// MARK: - Match cell

@MainActor
private final class SearchMatchCellView: NSTableCellView {

    private let iconView = NSImageView()
    private let previewLabel = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)

        // Xcode-style small "text lines" marker before each hit.
        iconView.image = NSImage(
            systemSymbolName: "text.alignleft", accessibilityDescription: nil
        )
        iconView.symbolConfiguration = .init(pointSize: 10, weight: .regular)
        iconView.contentTintColor = .tertiaryLabelColor
        iconView.setContentHuggingPriority(.required, for: .horizontal)

        previewLabel.font = .systemFont(ofSize: 13)
        previewLabel.lineBreakMode = .byTruncatingTail
        previewLabel.maximumNumberOfLines = 1
        previewLabel.cell?.truncatesLastVisibleLine = true

        iconView.translatesAutoresizingMaskIntoConstraints = false
        previewLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconView)
        addSubview(previewLabel)
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),

            previewLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 5),
            previewLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            previewLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(preview: String, hit: Range<Int>, isCurrent: Bool) {

        // Trim leading whitespace but keep the hit range aligned.
        let leading = preview.prefix(while: { $0 == " " || $0 == "\t" })
        let leadingUTF16 = leading.utf16.count
        let trimmed = String(preview.dropFirst(leading.count))

        // Xcode style: plain text with the hit emphasized (bold + accent tint).
        let attributed = NSMutableAttributedString(
            string: trimmed,
            attributes: [
                .font: NSFont.systemFont(ofSize: 13),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
        )
        let shifted = (hit.lowerBound - leadingUTF16)..<(hit.upperBound - leadingUTF16)
        if shifted.lowerBound >= 0, shifted.upperBound <= (trimmed as NSString).length {
            attributed.addAttributes(
                [
                    .font: NSFont.systemFont(ofSize: 13, weight: .bold),
                    .foregroundColor: NSColor.labelColor,
                    .backgroundColor: NSColor.findHighlightColor.withAlphaComponent(isCurrent ? 0.9 : 0.35),
                ],
                range: NSRange(location: shifted.lowerBound, length: shifted.count)
            )
            if isCurrent {
                attributed.addAttribute(
                    .foregroundColor, value: NSColor.black,
                    range: NSRange(location: shifted.lowerBound, length: shifted.count)
                )
            }
        }
        previewLabel.attributedStringValue = attributed
        toolTip = trimmed
    }
}
