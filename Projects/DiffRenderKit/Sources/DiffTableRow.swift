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
        mode: DiffDisplayMode = .unified
    ) -> [DiffTableRow] {
        var rows: [DiffTableRow] = []
        for (fileIndex, file) in document.files.enumerated() {
            rows.append(.fileHeader(fileIndex: fileIndex))
            if file.isBinary {
                rows.append(.placeholder(fileIndex: fileIndex, message: "二进制文件"))
                continue
            }
            if file.hunks.isEmpty {
                rows.append(.placeholder(fileIndex: fileIndex, message: "无文本变更"))
                continue
            }
            for (hunkIndex, hunk) in file.hunks.enumerated() {
                rows.append(.hunkHeader(fileIndex: fileIndex, hunkIndex: hunkIndex))
                switch mode {
                case .unified:
                    for lineIndex in hunk.lines.indices {
                        rows.append(.line(
                            fileIndex: fileIndex,
                            hunkIndex: hunkIndex,
                            lineIndex: lineIndex
                        ))
                    }
                case .split:
                    for pair in SplitRowPairer.pairs(for: hunk) {
                        rows.append(.splitLine(
                            fileIndex: fileIndex,
                            hunkIndex: hunkIndex,
                            oldLineIndex: pair.oldLineIndex,
                            newLineIndex: pair.newLineIndex
                        ))
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
    }

    private var content: Content = .none

    /// Selected character range within this row's text, drawn as a highlight.
    public var selectedRange: Range<Int>? {
        didSet {
            if selectedRange != oldValue { needsDisplay = true }
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

    public func configure(row: DiffTableRow, document: DiffDocument, theme: DiffTheme) {
        self.theme = theme
        switch row {
        case .fileHeader(let fileIndex):
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
            content = .hunkHeader(text: document.files[fileIndex].hunks[hunkIndex].headerText)
        case .line(let fileIndex, let hunkIndex, let lineIndex):
            content = .line(document.files[fileIndex].hunks[hunkIndex].lines[lineIndex])
        case .splitLine(let fileIndex, let hunkIndex, let oldLineIndex, let newLineIndex):
            let lines = document.files[fileIndex].hunks[hunkIndex].lines
            content = .splitLine(
                old: oldLineIndex.map { lines[$0] },
                new: newLineIndex.map { lines[$0] }
            )
        case .placeholder(_, let message):
            content = .placeholder(message)
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
            palette.hunkHeaderBackground.nsColor.setFill()
            context.fill(bounds)
            palette.gutterLine.nsColor.setFill()
            context.fill(NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1))

            let titleLine = makeCTLine(title, bold: true)
            draw(line: titleLine, at: 12, baseline: bounds.height - 11, in: context, color: palette.text.nsColor)
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
            drawSelectionHighlight(palette: palette, in: context)

        case .splitLine(let old, let new):
            drawSplitLine(old: old, new: new, palette: palette, baseline: baseline, in: context)
            drawSelectionHighlight(palette: palette, in: context)

        case .placeholder(let message):
            draw(
                line: makeCTLine(message),
                at: 12,
                baseline: baseline,
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

        let contentLine = makeCTLine(line.content)

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

        // 5. Content.
        draw(line: contentLine, at: contentStartX, baseline: baseline, in: context, color: palette.text.nsColor)
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
