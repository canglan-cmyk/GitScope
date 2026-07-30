import AppKit
import DiffCore

/// Virtualized multi-file diff list: an NSTableView with one row per diff
/// line (plus file/hunk header rows). Only visible rows are materialized,
/// so arbitrarily large documents render without hitting Core Animation
/// texture limits — the reason the previous flat-container approach went
/// blank on big diffs.
@MainActor
public final class DiffListViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {

    // MARK: Public API

    public var document: DiffDocument? {
        didSet {
            rebuildRows()
        }
    }

    /// Unified (stacked) or split (side-by-side) presentation.
    public var displayMode: DiffDisplayMode = .unified {
        didSet {
            guard displayMode != oldValue else { return }
            rebuildRows()
        }
    }

    private func rebuildRows() {
        rows = document.map { DiffTableRowBuilder.rows(for: $0, mode: displayMode) } ?? []
        selection = nil
        tableView.reloadData()
    }

    public var theme: DiffTheme = .default {
        didSet {
            metricsView.theme = theme
            tableView.rowHeight = metricsView.rowHeight
            tableView.backgroundColor = theme
                .palette(for: view.effectiveAppearance).background.nsColor
            tableView.reloadData()
        }
    }

    // MARK: Internals

    private var rows: [DiffTableRow] = []
    private let tableView = DiffSelectionTableView()
    private let scrollView = NSScrollView()
    /// Off-screen metrics provider (row height for the current theme/font).
    private let metricsView = DiffRowCellView(frame: .zero)

    private let fileHeaderRowHeight: CGFloat = 32

    public override func loadView() {
        tableView.selectionOwner = self

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("diff"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.intercellSpacing = .zero
        tableView.selectionHighlightStyle = .none
        tableView.allowsColumnResizing = false
        tableView.rowHeight = metricsView.rowHeight
        tableView.gridStyleMask = []
        tableView.style = .plain
        tableView.usesAutomaticRowHeights = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = true

        view = scrollView
    }

    public override func viewDidLayout() {
        super.viewDidLayout()
        // Single column tracks the scroll view width.
        if let column = tableView.tableColumns.first {
            let width = scrollView.contentSize.width
            if column.width != width, width > 0 {
                column.width = width
            }
        }
    }

    // MARK: NSTableViewDataSource

    public func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    // MARK: NSTableViewDelegate

    public func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        switch rows[row] {
        case .fileHeader:
            return fileHeaderRowHeight
        case .placeholder:
            return fileHeaderRowHeight
        case .hunkHeader, .line, .splitLine:
            return metricsView.rowHeight
        }
    }

    public func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        guard let document else { return nil }

        let cell: DiffRowCellView
        if let reused = tableView.makeView(
            withIdentifier: DiffRowCellView.reuseIdentifier, owner: self
        ) as? DiffRowCellView {
            cell = reused
        } else {
            cell = DiffRowCellView(frame: .zero)
            cell.identifier = DiffRowCellView.reuseIdentifier
        }
        cell.configure(row: rows[row], document: document, theme: theme)
        cell.selectedRange = selection?.range(
            inRow: row,
            textLength: cell.rowText.utf16.count
        )
        return cell
    }

    public func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        false
    }

    // MARK: Navigation

    /// Scrolls so the given file's header row is at the top of the view.
    public func scrollToFile(at fileIndex: Int) {
        guard let rowIndex = rows.firstIndex(where: {
            if case .fileHeader(let index) = $0 { return index == fileIndex }
            return false
        }) else { return }

        // scrollRowToVisible only guarantees visibility; pin to top instead.
        let rowRect = tableView.rect(ofRow: rowIndex)
        tableView.scroll(NSPoint(x: 0, y: rowRect.minY))
    }

    // MARK: Selection

    /// Current text selection, held in the model layer so it survives cell
    /// recycling in the virtualized table.
    private(set) var selection: DiffSelection? {
        didSet { applySelectionToVisibleCells() }
    }

    /// Full text of a row (used for hit-testing and copy).
    private func text(forRow row: Int) -> String {
        guard let document, rows.indices.contains(row) else { return "" }
        switch rows[row] {
        case .fileHeader(let fileIndex):
            let file = document.files[fileIndex]
            if case .renamed = file.change {
                return "\(file.oldPath ?? "?") → \(file.newPath ?? "?")"
            }
            return file.canonicalPath
        case .hunkHeader(let fileIndex, let hunkIndex):
            return document.files[fileIndex].hunks[hunkIndex].headerText
        case .line(let fileIndex, let hunkIndex, let lineIndex):
            return document.files[fileIndex].hunks[hunkIndex].lines[lineIndex].content
        case .splitLine(let fileIndex, let hunkIndex, let oldLineIndex, let newLineIndex):
            let lines = document.files[fileIndex].hunks[hunkIndex].lines
            let preferred = newLineIndex ?? oldLineIndex
            return preferred.map { lines[$0].content } ?? ""
        case .placeholder(_, let message):
            return message
        }
    }

    private func applySelectionToVisibleCells() {
        let visibleRows = tableView.rows(in: tableView.visibleRect)
        for row in visibleRows.lowerBound..<visibleRows.upperBound {
            guard let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false)
                as? DiffRowCellView else { continue }
            cell.selectedRange = selection?.range(
                inRow: row,
                textLength: cell.rowText.utf16.count
            )
        }
    }

    // Called by DiffSelectionTableView.

    func position(at point: NSPoint) -> DiffTextPosition? {
        let row = tableView.row(at: point)
        guard row >= 0 else { return nil }
        guard let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false)
            as? DiffRowCellView else {
            return DiffTextPosition(row: row, offset: 0)
        }
        let pointInCell = cell.convert(point, from: tableView)
        return DiffTextPosition(row: row, offset: cell.characterOffset(at: pointInCell))
    }

    func beginSelection(at position: DiffTextPosition) {
        selection = DiffSelection(anchor: position, focus: position)
    }

    func extendSelection(to position: DiffTextPosition) {
        guard var current = selection else { return }
        current.focus = position
        selection = current
    }

    func selectWord(at position: DiffTextPosition) {
        let text = text(forRow: position.row) as NSString
        guard text.length > 0 else { return }
        let offset = min(position.offset, text.length - 1)

        let wordChars = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_"))
        func isWordChar(_ index: Int) -> Bool {
            let char = text.character(at: index)
            guard let scalar = Unicode.Scalar(char) else { return false }
            return wordChars.contains(scalar)
        }

        guard isWordChar(offset) else { return }
        var start = offset
        while start > 0, isWordChar(start - 1) { start -= 1 }
        var end = offset + 1
        while end < text.length, isWordChar(end) { end += 1 }

        selection = DiffSelection(
            anchor: DiffTextPosition(row: position.row, offset: start),
            focus: DiffTextPosition(row: position.row, offset: end)
        )
    }

    func selectAll() {
        guard !rows.isEmpty else { return }
        let lastRow = rows.count - 1
        selection = DiffSelection(
            anchor: DiffTextPosition(row: 0, offset: 0),
            focus: DiffTextPosition(row: lastRow, offset: text(forRow: lastRow).utf16.count)
        )
    }

    func clearSelection() {
        selection = nil
    }

    /// Plain-text of the current selection: one line per row, no line
    /// numbers, no +/- markers — pasteable straight into code.
    func selectedText() -> String? {
        guard let selection, !selection.isEmpty else { return nil }
        var parts: [String] = []
        for row in selection.start.row...selection.end.row {
            let rowText = text(forRow: row) as NSString
            guard let range = selection.range(inRow: row, textLength: rowText.length) else { continue }
            parts.append(rowText.substring(
                with: NSRange(location: range.lowerBound, length: range.count)
            ))
        }
        let joined = parts.joined(separator: "\n")
        return joined.isEmpty ? nil : joined
    }

    func copySelection() {
        guard let text = selectedText() else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}

// MARK: - Selection-capable table view

/// NSTableView subclass that turns mouse drags into text selection and
/// handles ⌘C / ⌘A. Selection state lives in the owning controller.
@MainActor
final class DiffSelectionTableView: NSTableView {

    weak var selectionOwner: DiffListViewController?

    private var isDraggingSelection = false
    private var autoscrollTimer: Timer?

    override var acceptsFirstResponder: Bool { true }

    override func resetCursorRects() {
        addCursorRect(visibleRect, cursor: .iBeam)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        guard let owner = selectionOwner, let position = owner.position(at: point) else {
            selectionOwner?.clearSelection()
            return
        }

        if event.clickCount == 2 {
            owner.selectWord(at: position)
            return
        }

        owner.beginSelection(at: position)
        isDraggingSelection = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDraggingSelection, let owner = selectionOwner else { return }
        let point = convert(event.locationInWindow, from: nil)
        autoscroll(with: event)
        if let position = owner.position(at: point) {
            owner.extendSelection(to: position)
        }
    }

    override func mouseUp(with event: NSEvent) {
        isDraggingSelection = false
    }

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command),
           let key = event.charactersIgnoringModifiers?.lowercased() {
            switch key {
            case "c":
                selectionOwner?.copySelection()
                return
            case "a":
                selectionOwner?.selectAll()
                return
            default:
                break
            }
        }
        super.keyDown(with: event)
    }

    @objc func copy(_ sender: Any?) {
        selectionOwner?.copySelection()
    }

    @objc func selectAllRows(_ sender: Any?) {
        selectionOwner?.selectAll()
    }

    override func selectAll(_ sender: Any?) {
        selectionOwner?.selectAll()
    }
}
