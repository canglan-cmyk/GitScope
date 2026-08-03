import AppKit
import CoreText
import DiffCore

// MARK: - Row model

/// One row in the virtualized diff table: the whole multi-file diff document
/// is flattened into an array of these, and NSTableView materializes only
/// the visible ones.
public enum DiffTableRow: Sendable {
    /// File header: path (or `old → new` for renames) plus change stats.
    case fileHeader(fileIndex: Int)
    /// Hunk header line, e.g. `@@ -10,6 +10,8 @@ func foo()`.
    case hunkHeader(fileIndex: Int, hunkIndex: Int)
    /// A single diff line (unified mode).
    case line(fileIndex: Int, hunkIndex: Int, lineIndex: Int)
    /// An aligned pair of lines (split mode): old on the left, new on the right.
    case splitLine(fileIndex: Int, hunkIndex: Int, oldLineIndex: Int?, newLineIndex: Int?)
    /// Placeholder for binary or empty files.
    case placeholder(fileIndex: Int, message: String)
    /// Clickable row to expand context around hunks.
    case expandContext(fileIndex: Int)
    /// An inline review comment bubble.
    case comment(fileIndex: Int, commentIndex: Int)
}

/// How diff content is presented.
public enum DiffDisplayMode: Sendable, Equatable {
    case unified
    case split
}

/// Flattens a `DiffDocument` into table rows.
public enum DiffTableRowBuilder {
    public static func rows(
        for document: DiffDocument,
        mode: DiffDisplayMode = .unified,
        collapsedFiles: Set<Int> = [],
        comments: [InlineComment] = []
    ) -> [DiffTableRow] {
        // Build a lookup: path → line → [comment indices].
        var commentLookup: [String: [Int: [Int]]] = [:]
        for (idx, comment) in comments.enumerated() {
            guard comment.line > 0 else { continue }
            commentLookup[comment.path, default: [:]][comment.line, default: []].append(idx)
        }

        var rows: [DiffTableRow] = []
        for (fileIndex, file) in document.files.enumerated() {
            rows.append(.fileHeader(fileIndex: fileIndex))
            // Skip content rows for collapsed (reviewed) files.
            if collapsedFiles.contains(fileIndex) { continue }
            if file.isBinary {
                rows.append(.placeholder(fileIndex: fileIndex, message: "二进制文件"))
                continue
            }
            if file.hunks.isEmpty {
                rows.append(.placeholder(fileIndex: fileIndex, message: "无文本变更"))
                continue
            }
            let filePath = file.canonicalPath
            let fileComments = commentLookup[filePath] ?? [:]
            for (hunkIndex, hunk) in file.hunks.enumerated() {
                // Add expand-context row between hunks (gap indicator).
                if hunkIndex > 0 {
                    rows.append(.expandContext(fileIndex: fileIndex))
                }
                rows.append(.hunkHeader(fileIndex: fileIndex, hunkIndex: hunkIndex))
                switch mode {
                case .unified:
                    for lineIndex in hunk.lines.indices {
                        rows.append(.line(
                            fileIndex: fileIndex,
                            hunkIndex: hunkIndex,
                            lineIndex: lineIndex
                        ))
                        // Insert comment rows after the line they're attached to.
                        let diffLine = hunk.lines[lineIndex]
                        if let newLine = diffLine.newLineNumber,
                           let commentIndices = fileComments[newLine] {
                            for commentIdx in commentIndices {
                                rows.append(.comment(fileIndex: fileIndex, commentIndex: commentIdx))
                            }
                        }
                    }
                case .split:
                    for pair in SplitRowPairer.pairs(for: hunk) {
                        rows.append(.splitLine(
                            fileIndex: fileIndex,
                            hunkIndex: hunkIndex,
                            oldLineIndex: pair.oldLineIndex,
                            newLineIndex: pair.newLineIndex
                        ))
                        // Insert comments for the new-side line.
                        if let newIdx = pair.newLineIndex {
                            let diffLine = hunk.lines[newIdx]
                            if let newLine = diffLine.newLineNumber,
                               let commentIndices = fileComments[newLine] {
                                for commentIdx in commentIndices {
                                    rows.append(.comment(fileIndex: fileIndex, commentIndex: commentIdx))
                                }
                            }
                        }
                    }
                }
            }
        }
        return rows
    }
}

// MARK: - Cell view

/// Draws exactly one diff table row. Reused by NSTableView; assigning
/// `configure(...)` swaps in new content without view churn.
public final class DiffRowCellView: DiffRenderView {

    public static let reuseIdentifier = NSUserInterfaceItemIdentifier("DiffRowCell")

    private enum Content {
        case none
        case fileHeader(title: String, stats: String)
        case hunkHeader(text: String)
        case line(DiffLine)
        case splitLine(old: DiffLine?, new: DiffLine?)
        case placeholder(String)
        case expandContext
        case comment(InlineComment)
    }

    private var content: Content = .none

    // MARK: Review button (file headers only, PR mode)

    /// Whether the review checkmark button is visible (set by the controller).
    public var showsReviewButton: Bool = false {
        didSet {
            if showsReviewButton != oldValue {
                _ = reviewButton // ensure created
                reviewButton.isHidden = !showsReviewButton
            }
        }
    }

    /// Whether this file is marked as reviewed.
    public var isReviewed: Bool = false {
        didSet {
            if isReviewed != oldValue {
                let symbol = isReviewed ? "checkmark.circle.fill" : "circle"
                reviewButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
                reviewButton.contentTintColor = isReviewed ? .systemGreen : .tertiaryLabelColor
            }
        }
    }

    /// Called when the user clicks the review button; passes the file index.
    public var onToggleReview: ((Int) -> Void)?

    /// The file index for the current file header (used by the review callback).
    public var fileIndex: Int = -1

    /// Whether this file header is in collapsed state (content hidden).
    public var isCollapsed: Bool = false {
        didSet {
            if isCollapsed != oldValue { needsDisplay = true }
        }
    }

    private lazy var reviewButton: NSButton = {
        let btn = NSButton(
            image: NSImage(systemSymbolName: "circle", accessibilityDescription: nil)!,
            target: self,
            action: #selector(reviewButtonClicked)
        )
        btn.isBordered = false
        btn.imageScaling = .scaleProportionallyUpOrDown
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.isHidden = true
        btn.setContentHuggingPriority(.required, for: .horizontal)
        addSubview(btn)
        NSLayoutConstraint.activate([
            btn.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            btn.centerYAnchor.constraint(equalTo: centerYAnchor),
            btn.widthAnchor.constraint(equalToConstant: 20),
            btn.heightAnchor.constraint(equalToConstant: 20),
        ])
        return btn
    }()

    @objc private func reviewButtonClicked() {
        guard fileIndex >= 0 else { return }
        onToggleReview?(fileIndex)
    }

    /// Selected character range within this row's text, drawn as a highlight.
    public var selectedRange: Range<Int>? {
        didSet {
            if selectedRange != oldValue { needsDisplay = true }
        }
    }

    /// Search match ranges within this row's text (UTF-16 offsets).
    public var searchHighlights: [Range<Int>] = [] {
        didSet {
            if searchHighlights != oldValue { needsDisplay = true }
        }
    }

    /// The currently focused search match (drawn emphasized).
    public var currentSearchHighlight: Range<Int>? {
        didSet {
            if currentSearchHighlight != oldValue { needsDisplay = true }
        }
    }

    /// The plain text this row contributes to a copy operation.
    public var rowText: String {
        switch content {
        case .none: return ""
        case .fileHeader(let title, _): return title
        case .hunkHeader(let text): return text
        case .line(let line): return line.content
        case .splitLine(let old, let new): return (new ?? old)?.content ?? ""
        case .placeholder(let message): return message
        case .expandContext: return ""
        case .comment(let c): return c.body
        }
    }

    /// The x where selectable text starts (content column for lines,
    /// header inset otherwise).
    public var textOriginX: CGFloat {
        switch content {
        case .line: return contentStartX
        case .splitLine(let old, let new):
            // Selection/copy applies to the preferred (new-first) side.
            return new != nil
                ? paneWidth + splitGutterWidth + 2
                : splitGutterWidth + 2
        case .hunkHeader: return gutterWidth + round(0.4 * theme.fontSize)
        default: return 12
        }
    }

    /// Converts a point in view coordinates to a UTF-16 offset in `rowText`.
    public func characterOffset(at point: NSPoint) -> Int {
        let line = makeCTLine(rowText)
        let relative = CGPoint(x: max(point.x - textOriginX, 0), y: 0)
        let index = CTLineGetStringIndexForPosition(line, relative)
        return index == kCFNotFound ? 0 : index
    }

    // Layout constants (shared with UnifiedDiffView's geometry).
    private var gutterColumnWidth: CGFloat { round(4 * theme.fontSize) }
    private var gutterWidth: CGFloat { 2 * gutterColumnWidth }
    private var markerWidth: CGFloat { round(1.5 * theme.fontSize) }
    private var contentStartX: CGFloat { gutterWidth + markerWidth }

    // Split mode geometry: each pane is half the width, with a single
    // line-number gutter per side.
    private var paneWidth: CGFloat { floor(bounds.width / 2) }
    private var splitGutterWidth: CGFloat { gutterColumnWidth }

    // MARK: Configure

    /// The syntax language for the current file (used for highlighting).
    private var syntaxLanguage: SyntaxHighlighter.Language = .unknown

    public func configure(row: DiffTableRow, document: DiffDocument, theme: DiffTheme, comments: [InlineComment] = []) {
        self.theme = theme
        switch row {
        case .fileHeader(let fileIndex):
            syntaxLanguage = SyntaxHighlighter.language(forPath: document.files[fileIndex].canonicalPath)
            let file = document.files[fileIndex]
            let title: String
            if case .renamed = file.change {
                title = "\(file.oldPath ?? "?") → \(file.newPath ?? "?")"
            } else {
                title = file.canonicalPath
            }
            content = .fileHeader(
                title: title,
                stats: "+\(file.additionCount) −\(file.deletionCount)"
            )
        case .hunkHeader(let fileIndex, let hunkIndex):
            syntaxLanguage = SyntaxHighlighter.language(forPath: document.files[fileIndex].canonicalPath)
            content = .hunkHeader(text: document.files[fileIndex].hunks[hunkIndex].headerText)
        case .line(let fileIndex, let hunkIndex, let lineIndex):
            syntaxLanguage = SyntaxHighlighter.language(forPath: document.files[fileIndex].canonicalPath)
            content = .line(document.files[fileIndex].hunks[hunkIndex].lines[lineIndex])
        case .splitLine(let fileIndex, let hunkIndex, let oldLineIndex, let newLineIndex):
            syntaxLanguage = SyntaxHighlighter.language(forPath: document.files[fileIndex].canonicalPath)
            let lines = document.files[fileIndex].hunks[hunkIndex].lines
            content = .splitLine(
                old: oldLineIndex.map { lines[$0] },
                new: newLineIndex.map { lines[$0] }
            )
        case .placeholder(_, let message):
            content = .placeholder(message)
        case .expandContext:
            content = .expandContext
        case .comment(_, let commentIndex):
            if comments.indices.contains(commentIndex) {
                content = .comment(comments[commentIndex])
            } else {
                content = .none
            }
        }
        needsDisplay = true
    }

    // MARK: Drawing

    public override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        defer { context.restoreGState() }

        let palette = self.palette
        palette.background.nsColor.setFill()
        context.fill(bounds)

        let baseline = baselineY(forRowTop: 0)

        switch content {
        case .none:
            break

        case .fileHeader(let title, let stats):
            // Dimmer background for collapsed (reviewed) files.
            if isCollapsed {
                palette.hunkHeaderBackground.nsColor.withAlphaComponent(0.5).setFill()
            } else {
                palette.hunkHeaderBackground.nsColor.setFill()
            }
            context.fill(bounds)
            palette.gutterLine.nsColor.setFill()
            context.fill(NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1))

            // Collapse indicator: ▶ (collapsed) or ▼ (expanded).
            let indicator = isCollapsed ? "▶" : "▼"
            let indicatorLine = makeCTLine(indicator)
            draw(line: indicatorLine, at: 4, baseline: bounds.height - 11, in: context, color: palette.secondaryText.nsColor)

            let titleLine = makeCTLine(title, bold: true)
            let titleColor = isCollapsed ? palette.secondaryText.nsColor : palette.text.nsColor
            draw(line: titleLine, at: 18, baseline: bounds.height - 11, in: context, color: titleColor)

            // "已看" label for collapsed files.
            if isCollapsed {
                let badge = makeCTLine("✓ 已看")
                let badgeWidth = CTLineGetTypographicBounds(badge, nil, nil, nil)
                draw(
                    line: badge,
                    at: bounds.width - CGFloat(badgeWidth) - 40,
                    baseline: bounds.height - 11,
                    in: context,
                    color: NSColor.systemGreen
                )
            }

            let statsLine = makeCTLine(stats)
            let statsWidth = CTLineGetTypographicBounds(statsLine, nil, nil, nil)
            draw(
                line: statsLine,
                at: bounds.width - CGFloat(statsWidth) - 12,
                baseline: bounds.height - 11,
                in: context,
                color: palette.secondaryText.nsColor
            )

        case .hunkHeader(let text):
            palette.hunkHeaderBackground.nsColor.setFill()
            context.fill(bounds.insetBy(dx: 0, dy: 1))
            draw(
                line: makeCTLine(text),
                at: gutterWidth + round(0.4 * theme.fontSize),
                baseline: baseline,
                in: context,
                color: palette.hunkHeaderText.nsColor
            )
            drawGutterSeparators(palette: palette, in: context)

        case .line(let line):
            drawDiffLine(line, palette: palette, baseline: baseline, in: context)
            drawGutterSeparators(palette: palette, in: context)
            drawSearchHighlights(in: context)
            drawSelectionHighlight(palette: palette, in: context)

        case .splitLine(let old, let new):
            drawSplitLine(old: old, new: new, palette: palette, baseline: baseline, in: context)
            drawSearchHighlights(in: context)
            drawSelectionHighlight(palette: palette, in: context)

        case .placeholder(let message):
            draw(
                line: makeCTLine(message),
                at: 12,
                baseline: baseline,
                in: context,
                color: palette.secondaryText.nsColor
            )

        case .expandContext:
            // Draw a centered "⋯ 展开更多上下文" clickable row.
            palette.hunkHeaderBackground.nsColor.withAlphaComponent(0.3).setFill()
            context.fill(bounds)
            let text = "⋯ 展开更多上下文"
            let ctLine = makeCTLine(text)
            let lineWidth = CTLineGetTypographicBounds(ctLine, nil, nil, nil)
            let centerX = (bounds.width - CGFloat(lineWidth)) / 2
            draw(
                line: ctLine,
                at: centerX,
                baseline: bounds.height / 2 + 4,
                in: context,
                color: NSColor.controlAccentColor
            )

        case .comment(let comment):
            // Draw comment bubble with author and body.
            let bubbleInset: CGFloat = 24
            let bubbleRect = bounds.insetBy(dx: bubbleInset, dy: 3)
            // Background.
            let bgColor = NSColor.controlAccentColor.withAlphaComponent(0.08)
            bgColor.setFill()
            let path = NSBezierPath(roundedRect: bubbleRect, xRadius: 6, yRadius: 6)
            path.fill()
            // Left accent bar.
            NSColor.controlAccentColor.withAlphaComponent(0.5).setFill()
            context.fill(NSRect(x: bubbleInset, y: 3, width: 3, height: bounds.height - 6))
            // Author + time.
            let header = "\(comment.author) · \(comment.relativeTime)"
            let headerLine = makeCTLine(header, bold: true)
            draw(
                line: headerLine,
                at: bubbleInset + 10,
                baseline: 15,
                in: context,
                color: palette.text.nsColor
            )
            // Body (first line only, truncated).
            let bodyText = comment.body.components(separatedBy: .newlines).first ?? comment.body
            let bodyLine = makeCTLine(String(bodyText.prefix(120)))
            draw(
                line: bodyLine,
                at: bubbleInset + 10,
                baseline: 33,
                in: context,
                color: palette.secondaryText.nsColor
            )
        }
    }

    private func drawDiffLine(
        _ line: DiffLine,
        palette: DiffPalette,
        baseline: CGFloat,
        in context: CGContext
    ) {
        // 1. Row background.
        switch line.change {
        case .addition:
            palette.addedBackground.nsColor.setFill()
            context.fill(bounds)
        case .deletion:
            palette.deletedBackground.nsColor.setFill()
            context.fill(bounds)
        case .context:
            break
        }

        // Syntax-highlighted content line (falls back to plain if unknown language).
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let highlighted = SyntaxHighlighter.highlight(
            line.content,
            language: syntaxLanguage,
            font: font,
            baseColor: palette.text.nsColor,
            isDark: isDark
        )
        let contentLine: CTLine
        if let highlighted {
            contentLine = CTLineCreateWithAttributedString(highlighted)
        } else {
            contentLine = makeCTLine(line.content)
        }

        // 2. Intra-line emphasis.
        if let highlight = line.intralineHighlight, line.change != .context {
            let color = (line.change == .addition ? palette.addedHighlight : palette.deletedHighlight).nsColor
            let startX = CTLineGetOffsetForStringIndex(contentLine, highlight.lowerBound, nil)
            let endX = CTLineGetOffsetForStringIndex(contentLine, highlight.upperBound, nil)
            if endX > startX {
                color.setFill()
                context.fill(NSRect(
                    x: contentStartX + round(startX),
                    y: 0,
                    width: round(endX) - round(startX),
                    height: bounds.height
                ))
            }
        }

        // 3. Line numbers.
        let numberInset = round(0.5 * theme.fontSize)
        let secondary = palette.secondaryText.nsColor
        if let oldNumber = line.oldLineNumber {
            let text = oldNumber >= 100_000 ? "9999…" : String(format: "%5d", oldNumber)
            draw(line: makeCTLine(text), at: numberInset, baseline: baseline, in: context, color: secondary)
        }
        if let newNumber = line.newLineNumber {
            let text = newNumber >= 100_000 ? "9999…" : String(format: "%5d", newNumber)
            draw(line: makeCTLine(text), at: gutterColumnWidth + numberInset, baseline: baseline, in: context, color: secondary)
        }

        // 4. +/- marker.
        switch line.change {
        case .addition:
            draw(line: makeCTLine("+"), at: gutterWidth + 2, baseline: baseline, in: context, color: secondary)
        case .deletion:
            draw(line: makeCTLine("-"), at: gutterWidth + 2, baseline: baseline, in: context, color: secondary)
        case .context:
            break
        }

        // 5. Content (syntax-highlighted lines draw their own colors).
        if highlighted != nil {
            // Highlighted line has per-character colors; draw without overriding.
            context.saveGState()
            context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
            context.textPosition = CGPoint(x: contentStartX, y: baseline)
            CTLineDraw(contentLine, context)
            context.restoreGState()
        } else {
            draw(line: contentLine, at: contentStartX, baseline: baseline, in: context, color: palette.text.nsColor)
        }
    }

    private func drawSplitLine(
        old: DiffLine?,
        new: DiffLine?,
        palette: DiffPalette,
        baseline: CGFloat,
        in context: CGContext
    ) {
        let numberInset = round(0.5 * theme.fontSize)
        let secondary = palette.secondaryText.nsColor

        // --- Left pane (old side) ---
        context.saveGState()
        context.clip(to: NSRect(x: 0, y: 0, width: paneWidth, height: bounds.height))

        if let old {
            if old.change == .deletion {
                palette.deletedBackground.nsColor.setFill()
                context.fill(NSRect(x: 0, y: 0, width: paneWidth, height: bounds.height))
            }
            let contentLine = makeCTLine(old.content)
            if old.change == .deletion, let highlight = old.intralineHighlight {
                drawIntraline(
                    highlight, line: contentLine,
                    originX: splitGutterWidth + 2,
                    color: palette.deletedHighlight.nsColor, in: context
                )
            }
            if let number = old.oldLineNumber {
                let text = number >= 100_000 ? "9999…" : String(format: "%5d", number)
                draw(line: makeCTLine(text), at: numberInset, baseline: baseline, in: context, color: secondary)
            }
            draw(
                line: contentLine, at: splitGutterWidth + 2,
                baseline: baseline, in: context, color: palette.text.nsColor
            )
        } else {
            // Empty placeholder: subtle hatched background.
            palette.hunkHeaderBackground.nsColor.withAlphaComponent(0.4).setFill()
            context.fill(NSRect(x: 0, y: 0, width: paneWidth, height: bounds.height))
        }
        context.restoreGState()

        // --- Right pane (new side) ---
        context.saveGState()
        context.clip(to: NSRect(
            x: paneWidth, y: 0,
            width: bounds.width - paneWidth, height: bounds.height
        ))

        if let new {
            if new.change == .addition {
                palette.addedBackground.nsColor.setFill()
                context.fill(NSRect(
                    x: paneWidth, y: 0,
                    width: bounds.width - paneWidth, height: bounds.height
                ))
            }
            let contentLine = makeCTLine(new.content)
            if new.change == .addition, let highlight = new.intralineHighlight {
                drawIntraline(
                    highlight, line: contentLine,
                    originX: paneWidth + splitGutterWidth + 2,
                    color: palette.addedHighlight.nsColor, in: context
                )
            }
            if let number = new.newLineNumber {
                let text = number >= 100_000 ? "9999…" : String(format: "%5d", number)
                draw(
                    line: makeCTLine(text), at: paneWidth + numberInset,
                    baseline: baseline, in: context, color: secondary
                )
            }
            draw(
                line: contentLine, at: paneWidth + splitGutterWidth + 2,
                baseline: baseline, in: context, color: palette.text.nsColor
            )
        } else {
            palette.hunkHeaderBackground.nsColor.withAlphaComponent(0.4).setFill()
            context.fill(NSRect(
                x: paneWidth, y: 0,
                width: bounds.width - paneWidth, height: bounds.height
            ))
        }
        context.restoreGState()

        // --- Separators: gutters and the center divider ---
        context.saveGState()
        context.setStrokeColor(palette.gutterLine.nsColor.cgColor)
        context.setLineWidth(1)
        for x in [
            splitGutterWidth - 0.5,
            paneWidth - 0.5,
            paneWidth + splitGutterWidth - 0.5,
        ] {
            context.move(to: CGPoint(x: x, y: 0))
            context.addLine(to: CGPoint(x: x, y: bounds.height))
        }
        context.strokePath()
        context.restoreGState()
    }

    private func drawIntraline(
        _ highlight: Range<Int>,
        line: CTLine,
        originX: CGFloat,
        color: NSColor,
        in context: CGContext
    ) {
        let startX = CTLineGetOffsetForStringIndex(line, highlight.lowerBound, nil)
        let endX = CTLineGetOffsetForStringIndex(line, highlight.upperBound, nil)
        guard endX > startX else { return }
        color.setFill()
        context.fill(NSRect(
            x: originX + round(startX),
            y: 0,
            width: round(endX) - round(startX),
            height: bounds.height
        ))
    }

    private func drawSearchHighlights(in context: CGContext) {
        guard !searchHighlights.isEmpty else { return }
        let line = makeCTLine(rowText)
        for range in searchHighlights where !range.isEmpty {
            let startX = CTLineGetOffsetForStringIndex(line, range.lowerBound, nil)
            let endX = CTLineGetOffsetForStringIndex(line, range.upperBound, nil)
            guard endX > startX else { continue }
            let isCurrent = range == currentSearchHighlight
            let color: NSColor = isCurrent
                ? .systemOrange.withAlphaComponent(0.85)
                : .systemYellow.withAlphaComponent(0.45)
            color.setFill()
            context.fill(NSRect(
                x: textOriginX + startX,
                y: isCurrent ? 1 : 2,
                width: endX - startX,
                height: bounds.height - (isCurrent ? 2 : 4)
            ))
        }
    }

    private func drawSelectionHighlight(palette: DiffPalette, in context: CGContext) {
        guard let range = selectedRange, !range.isEmpty else { return }
        let line = makeCTLine(rowText)
        let startX = CTLineGetOffsetForStringIndex(line, range.lowerBound, nil)
        let endX = CTLineGetOffsetForStringIndex(line, range.upperBound, nil)
        guard endX > startX else { return }
        NSColor.selectedTextBackgroundColor.withAlphaComponent(0.45).setFill()
        context.fill(NSRect(
            x: textOriginX + startX,
            y: 0,
            width: endX - startX,
            height: bounds.height
        ))
    }

    private func drawGutterSeparators(palette: DiffPalette, in context: CGContext) {
        context.saveGState()
        context.setStrokeColor(palette.gutterLine.nsColor.cgColor)
        context.setLineWidth(1)
        for x in [gutterColumnWidth - 0.5, gutterWidth - 0.5] {
            context.move(to: CGPoint(x: x, y: 0))
            context.addLine(to: CGPoint(x: x, y: bounds.height))
        }
        context.strokePath()
        context.restoreGState()
    }
}
