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

    /// When true, file header rows show a review checkmark button.
    public var showsReviewButtons: Bool = false {
        didSet { if showsReviewButtons != oldValue { tableView.reloadData() } }
    }

    /// Returns whether a file is reviewed (queried per file header row).
    public var isFileReviewed: ((Int) -> Bool)?

    /// Called when the user clicks the review button on a file header.
    public var onToggleFileReview: ((Int) -> Void)?

    /// Called when the user clicks an "expand context" row. Passes the file index.
    public var onExpandContext: (() -> Void)?

    /// Inline comments to display in the diff. Keyed by file path → line number → comments.
    public var inlineComments: [InlineComment] = [] {
        didSet { rebuildRows() }
    }

    /// Callback to load an image for a file at a given ref. Returns NSImage or nil.
    /// Called with (fileIndex) and should return the loaded NSImage asynchronously.
    public var imageForFile: ((Int) -> NSImage?)?

    /// Cache of loaded images keyed by file index.
    public var imageCache: [Int: NSImage] = [:]

    /// Files that are collapsed (only header shown, content hidden).
    public private(set) var collapsedFiles: Set<Int> = []

    /// Collapse a file (hide its diff content, show only header).
    public func collapseFile(at fileIndex: Int) {
        collapsedFiles.insert(fileIndex)
        rebuildRows()
    }

    /// Expand a previously collapsed file.
    public func expandFile(at fileIndex: Int) {
        collapsedFiles.remove(fileIndex)
        rebuildRows()
    }

    /// Toggle collapse state for a file.
    public func toggleCollapse(at fileIndex: Int) {
        if collapsedFiles.contains(fileIndex) {
            collapsedFiles.remove(fileIndex)
        } else {
            collapsedFiles.insert(fileIndex)
        }
        rebuildRows()
    }

    /// Unified (stacked) or split (side-by-side) presentation.
    public var displayMode: DiffDisplayMode = .unified {
        didSet {
            guard displayMode != oldValue else { return }
            rebuildRows()
        }
    }

    private var isRebuilding = false

    private func rebuildRows() {
        isRebuilding = true
        rows = document.map {
            DiffTableRowBuilder.rows(
                for: $0, mode: displayMode,
                collapsedFiles: collapsedFiles,
                comments: inlineComments
            )
        } ?? []
        selection = nil
        if !searchQuery.isEmpty { recomputeSearchMatches() }
        tableView.reloadData()
        isRebuilding = false
    }

    // MARK: Search

    public struct SearchMatch: Sendable {
        public let row: Int
        public let range: Range<Int> // UTF-16 offsets within the row text
        public let filePath: String
        public let fileIndex: Int
        public let lineNumber: Int? // new-side line number (old side if deletion)
        public let preview: String // full row text for list previews
    }

    public enum SearchScope: Sendable {
        case allLines
        case changedLinesOnly
    }

    public private(set) var searchMatches: [SearchMatch] = []
    public private(set) var currentMatchIndex: Int = 0
    public var searchScope: SearchScope = .allLines {
        didSet { if !searchQuery.isEmpty { search(searchQuery) } }
    }

    private var searchQuery: String = ""

    /// Called whenever matches change: (matchCount, currentIndex).
    public var onSearchResultsChanged: ((Int, Int) -> Void)?

    /// Runs a case-insensitive search across all diff line rows.
    public func search(_ query: String) {
        searchQuery = query
        recomputeSearchMatches()
        currentMatchIndex = 0
        tableView.reloadData()
        if !searchMatches.isEmpty {
            revealMatch(at: 0)
        }
        onSearchResultsChanged?(searchMatches.count, searchMatches.isEmpty ? 0 : 1)
    }

    public func clearSearch() {
        searchQuery = ""
        searchMatches = []
        currentMatchIndex = 0
        tableView.reloadData()
        onSearchResultsChanged?(0, 0)
    }

    public func nextMatch() {
        guard !searchMatches.isEmpty else { return }
        currentMatchIndex = (currentMatchIndex + 1) % searchMatches.count
        revealMatch(at: currentMatchIndex)
        onSearchResultsChanged?(searchMatches.count, currentMatchIndex + 1)
    }

    public func previousMatch() {
        guard !searchMatches.isEmpty else { return }
        currentMatchIndex = (currentMatchIndex - 1 + searchMatches.count) % searchMatches.count
        revealMatch(at: currentMatchIndex)
        onSearchResultsChanged?(searchMatches.count, currentMatchIndex + 1)
    }

    /// Jumps directly to a specific match (results-panel click).
    public func goToMatch(at index: Int) {
        guard searchMatches.indices.contains(index) else { return }
        currentMatchIndex = index
        revealMatch(at: index)
        onSearchResultsChanged?(searchMatches.count, index + 1)
    }

    private func recomputeSearchMatches() {
        searchMatches = []
        guard let document, !searchQuery.isEmpty else { return }
        let needle = searchQuery

        for (rowIndex, row) in rows.enumerated() {
            // Scope filtering: only diff-line rows are searchable.
            var lineChange: LineChange?
            switch row {
            case .line(let f, let h, let l):
                lineChange = document.files[f].hunks[h].lines[l].change
            case .splitLine(let f, let h, let oldL, let newL):
                let lines = document.files[f].hunks[h].lines
                if let idx = newL ?? oldL { lineChange = lines[idx].change }
            default:
                continue
            }
            if searchScope == .changedLinesOnly, lineChange == .context { continue }

            // Location details for the results panel.
            var filePath = ""
            var fileIndex = 0
            var lineNumber: Int?
            switch row {
            case .line(let f, let h, let l):
                fileIndex = f
                filePath = document.files[f].canonicalPath
                let line = document.files[f].hunks[h].lines[l]
                lineNumber = line.newLineNumber ?? line.oldLineNumber
            case .splitLine(let f, let h, let oldL, let newL):
                fileIndex = f
                filePath = document.files[f].canonicalPath
                let lines = document.files[f].hunks[h].lines
                if let idx = newL ?? oldL {
                    let line = lines[idx]
                    lineNumber = line.newLineNumber ?? line.oldLineNumber
                }
            default:
                break
            }

            let text = text(forRow: rowIndex) as NSString
            var searchRange = NSRange(location: 0, length: text.length)
            while searchRange.length > 0 {
                let found = text.range(
                    of: needle, options: [.caseInsensitive], range: searchRange
                )
                guard found.location != NSNotFound else { break }
                searchMatches.append(SearchMatch(
                    row: rowIndex,
                    range: found.location..<(found.location + found.length),
                    filePath: filePath,
                    fileIndex: fileIndex,
                    lineNumber: lineNumber,
                    preview: text as String
                ))
                let nextLocation = found.location + max(found.length, 1)
                searchRange = NSRange(location: nextLocation, length: text.length - nextLocation)
            }
        }
    }

    private func revealMatch(at index: Int) {
        guard searchMatches.indices.contains(index) else { return }
        let match = searchMatches[index]
        tableView.scrollRowToVisible(match.row)
        applySearchToVisibleCells()
    }

    /// Search highlight ranges for a given row (current match emphasized).
    func searchHighlights(forRow row: Int) -> (all: [Range<Int>], current: Range<Int>?) {
        guard !searchMatches.isEmpty else { return ([], nil) }
        let all = searchMatches.filter { $0.row == row }.map(\.range)
        var current: Range<Int>?
        if searchMatches.indices.contains(currentMatchIndex),
           searchMatches[currentMatchIndex].row == row {
            current = searchMatches[currentMatchIndex].range
        }
        return (all, current)
    }

    private func applySearchToVisibleCells() {
        let visibleRows = tableView.rows(in: tableView.visibleRect)
        for row in visibleRows.lowerBound..<visibleRows.upperBound {
            guard let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false)
                as? DiffRowCellView else { continue }
            let highlights = searchHighlights(forRow: row)
            cell.searchHighlights = highlights.all
            cell.currentSearchHighlight = highlights.current
        }
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
    /// Public read-only access to the current row array.
    public var currentRows: [DiffTableRow] { rows }
    private let tableView = DiffSelectionTableView()

    /// Scrolls the table to make the given row visible.
    public func scrollToRow(_ row: Int) {
        guard rows.indices.contains(row) else { return }
        tableView.scrollRowToVisible(row)
    }

    /// Reloads the diff table (e.g. after toggling review state).
    public func reloadTable() {
        tableView.reloadData()
    }
    private let scrollView = NSScrollView()
    /// Off-screen metrics provider (row height for the current theme/font).
    private let metricsView = DiffRowCellView(frame: .zero)

    private let fileHeaderRowHeight: CGFloat = 28

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
        guard rows.indices.contains(row) else { return metricsView.rowHeight }
        switch rows[row] {
        case .fileHeader:
            return fileHeaderRowHeight
        case .placeholder:
            return fileHeaderRowHeight
        case .expandContext:
            return 24
        case .comment:
            return 44
        case .imagePreview(let fileIndex):
            if let img = imageCache[fileIndex] {
                return ImagePreviewCellView.preferredHeight(for: img, maxWidth: tableView.bounds.width)
            }
            return 200 // Default while loading.
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

        // Image preview rows use a different cell type.
        if case .imagePreview(let fileIndex) = rows[row] {
            let imgCell: ImagePreviewCellView
            if let reused = tableView.makeView(
                withIdentifier: ImagePreviewCellView.reuseIdentifier, owner: self
            ) as? ImagePreviewCellView {
                imgCell = reused
            } else {
                imgCell = ImagePreviewCellView(frame: .zero)
                imgCell.identifier = ImagePreviewCellView.reuseIdentifier
            }
            let file = document.files[fileIndex]
            let img = imageCache[fileIndex] ?? imageForFile?(fileIndex)
            if let loadedImg = img, imageCache[fileIndex] == nil {
                imageCache[fileIndex] = loadedImg
                // Reload row height now that we have the image.
                tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integer: row))
            }
            let status: String
            let changeType: ImagePreviewCellView.ChangeType
            switch file.change {
            case .added:
                status = "新增"
                changeType = .added
            case .deleted:
                status = "删除"
                changeType = .deleted
            case .modified:
                status = "修改"
                changeType = .modified
            case .renamed:
                status = "重命名"
                changeType = .modified
            default:
                status = "图片"
                changeType = .modified
            }
            imgCell.configureSingle(image: img, status: status, changeType: changeType)
            return imgCell
        }

        let cell: DiffRowCellView
        if let reused = tableView.makeView(
            withIdentifier: DiffRowCellView.reuseIdentifier, owner: self
        ) as? DiffRowCellView {
            cell = reused
        } else {
            cell = DiffRowCellView(frame: .zero)
            cell.identifier = DiffRowCellView.reuseIdentifier
        }
        cell.configure(row: rows[row], document: document, theme: theme, comments: inlineComments)
        cell.selectedRange = selection?.range(
            inRow: row,
            textLength: cell.rowText.utf16.count
        )
        let highlights = searchHighlights(forRow: row)
        cell.searchHighlights = highlights.all
        cell.currentSearchHighlight = highlights.current

        // Review button for file headers in PR mode.
        if case .fileHeader(let fileIndex) = rows[row] {
            cell.fileIndex = fileIndex
            cell.showsReviewButton = showsReviewButtons
            cell.isReviewed = isFileReviewed?(fileIndex) ?? false
            cell.isCollapsed = collapsedFiles.contains(fileIndex)
            cell.onToggleReview = { [weak self] idx in
                self?.onToggleFileReview?(idx)
            }
        } else {
            cell.showsReviewButton = false
            cell.onToggleReview = nil
            cell.isCollapsed = false
        }

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
        case .expandContext:
            return ""
        case .comment(_, let idx):
            return inlineComments.indices.contains(idx) ? inlineComments[idx].body : ""
        case .imagePreview:
            return ""
        }
    }

    private func applySelectionToVisibleCells() {
        guard !isRebuilding else { return }
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

    /// Returns true if the given row is an expandContext row.
    func isExpandContextRow(at row: Int) -> Bool {
        guard rows.indices.contains(row) else { return false }
        if case .expandContext = rows[row] { return true }
        return false
    }

    /// Returns true if the given row is a file header row.
    func isFileHeaderRow(at row: Int) -> Bool {
        guard rows.indices.contains(row) else { return false }
        if case .fileHeader = rows[row] { return true }
        return false
    }

    /// Returns the file index for a given row (must be a file header row).
    func fileIndex(forRow row: Int) -> Int {
        guard rows.indices.contains(row), case .fileHeader(let idx) = rows[row] else { return -1 }
        return idx
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

    // MARK: Selection context (for reference finding / editor jump)

    /// Information about where the current selection lives in the diff.
    public struct SelectionContext: Sendable {
        public let filePath: String
        /// New-side line number of the selection start (nil for pure deletions).
        public let lineNumber: Int?
        public let selectedText: String
    }

    /// Resolves the current selection to file/line/text, or nil when nothing
    /// meaningful is selected.
    public func selectionContext() -> SelectionContext? {
        guard let selection, !selection.isEmpty,
              let document,
              let text = selectedText(), !text.isEmpty else { return nil }

        let row = selection.start.row
        guard rows.indices.contains(row) else { return nil }

        var fileIndex: Int?
        var lineNumber: Int?
        switch rows[row] {
        case .line(let f, let h, let l):
            fileIndex = f
            let line = document.files[f].hunks[h].lines[l]
            lineNumber = line.newLineNumber ?? line.oldLineNumber
        case .splitLine(let f, let h, let oldL, let newL):
            fileIndex = f
            let lines = document.files[f].hunks[h].lines
            if let idx = newL ?? oldL {
                let line = lines[idx]
                lineNumber = line.newLineNumber ?? line.oldLineNumber
            }
        case .fileHeader(let f), .hunkHeader(let f, _), .placeholder(let f, _), .expandContext(let f), .comment(let f, _), .imagePreview(let f):
            fileIndex = f
        }

        guard let fileIndex, document.files.indices.contains(fileIndex) else { return nil }
        return SelectionContext(
            filePath: document.files[fileIndex].canonicalPath,
            lineNumber: lineNumber,
            selectedText: text
        )
    }

    /// Context-menu callbacks installed by the app layer.
    public var onFindReferences: ((SelectionContext) -> Void)?
    public var onOpenSelectionInEditor: ((SelectionContext) -> Void)?

    func makeContextMenu() -> NSMenu? {
        let menu = NSMenu()

        if selectedText() != nil {
            let copyItem = NSMenuItem(title: "复制", action: #selector(DiffSelectionTableView.copy(_:)), keyEquivalent: "")
            copyItem.target = tableView
            menu.addItem(copyItem)
        }

        if let context = selectionContext() {
            let word = context.selectedText
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !word.isEmpty, !word.contains("\n"), word.count <= 120,
               onFindReferences != nil {
                let title = word.count > 24
                    ? "全仓库查找引用…"
                    : "全仓库查找“\(word)”的引用"
                let findItem = NSMenuItem(title: title, action: #selector(contextFindReferences), keyEquivalent: "")
                findItem.target = self
                menu.addItem(findItem)
            }
            if onOpenSelectionInEditor != nil {
                let openItem = NSMenuItem(
                    title: "在编辑器中打开\(context.lineNumber.map { "（第 \($0) 行）" } ?? "")",
                    action: #selector(contextOpenInEditor), keyEquivalent: ""
                )
                openItem.target = self
                menu.addItem(openItem)
            }
        }

        return menu.items.isEmpty ? nil : menu
    }

    @objc private func contextFindReferences() {
        guard let context = selectionContext() else { return }
        onFindReferences?(context)
    }

    @objc private func contextOpenInEditor() {
        guard let context = selectionContext() else { return }
        onOpenSelectionInEditor?(context)
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
        guard let owner = selectionOwner else {
            super.resetCursorRects()
            return
        }
        let visibleRows = rows(in: visibleRect)
        for row in visibleRows.lowerBound..<visibleRows.upperBound {
            let rowRect = rect(ofRow: row)
            if owner.isFileHeaderRow(at: row) || owner.isExpandContextRow(at: row) {
                addCursorRect(rowRect, cursor: .pointingHand)
            } else {
                addCursorRect(rowRect, cursor: .iBeam)
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)

        // Check if clicking an expand-context row.
        let clickedRow = row(at: point)
        if clickedRow >= 0, let owner = selectionOwner {
            if owner.isExpandContextRow(at: clickedRow) {
                owner.onExpandContext?()
                return
            }
            // Click anywhere on file header row toggles collapse.
            if owner.isFileHeaderRow(at: clickedRow) {
                owner.toggleCollapse(at: owner.fileIndex(forRow: clickedRow))
                return
            }
        }

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

    override func menu(for event: NSEvent) -> NSMenu? {
        // Right-click on an unselected spot: select the word under cursor
        // first so "find references" has something to work with.
        let point = convert(event.locationInWindow, from: nil)
        if let owner = selectionOwner {
            if owner.selectedText() == nil, let position = owner.position(at: point) {
                owner.selectWord(at: position)
            }
            return owner.makeContextMenu()
        }
        return super.menu(for: event)
    }
}
