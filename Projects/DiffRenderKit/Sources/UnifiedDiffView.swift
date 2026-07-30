import AppKit
import CoreText
import DiffCore

/// Unified (single-column) diff view for one file.
///
/// Design (see docs/GitUpKit-diff渲染设计解析与Swift化方案.md):
/// - A flat array of `RowRecord`s is built once per `fileDiff` assignment;
///   every visible row (hunk header or diff line) is one record with its
///   pre-built `CTLine`.
/// - Fixed row height makes all geometry a single division; total height is
///   `rows.count * rowHeight`.
/// - `draw(_:)` computes the visible row interval from the dirty rect and
///   only draws those rows — the row-level virtualization that keeps huge
///   diffs at 60 fps.
public final class UnifiedDiffView: DiffRenderView, DiffRenderer {

    // MARK: Row model

    private enum RowKind {
        case hunkHeader
        case line(LineChange)
    }

    private struct RowRecord {
        let kind: RowKind
        let oldLineNumber: Int?
        let newLineNumber: Int?
        let ctLine: CTLine
        /// Character range (offsets into the line content) to emphasize.
        let intralineHighlight: Range<Int>?
    }

    private var rows: [RowRecord] = []
    private var cachedWidth: CGFloat = -1

    // MARK: Layout constants

    private var gutterColumnWidth: CGFloat { round(4 * theme.fontSize) }
    private var gutterWidth: CGFloat { 2 * gutterColumnWidth }
    private var markerWidth: CGFloat { round(1.5 * theme.fontSize) }
    private var contentStartX: CGFloat { gutterWidth + markerWidth }

    // MARK: DiffRenderer

    public var view: NSView { self }

    public var fileDiff: FileDiff? {
        didSet { rebuildRows() }
    }

    public func layoutHeight(forWidth width: CGFloat) -> CGFloat {
        cachedWidth = width
        return CGFloat(rows.count) * rowHeight
    }

    // MARK: Row building

    public override func didRebuildFontMetrics() {
        rebuildRows()
    }

    private func rebuildRows() {
        rows.removeAll(keepingCapacity: true)
        guard let fileDiff else {
            invalidateSize()
            return
        }

        for hunk in fileDiff.hunks {
            rows.append(RowRecord(
                kind: .hunkHeader,
                oldLineNumber: nil,
                newLineNumber: nil,
                ctLine: makeCTLine(hunk.headerText),
                intralineHighlight: nil
            ))
            for line in hunk.lines {
                rows.append(RowRecord(
                    kind: .line(line.change),
                    oldLineNumber: line.oldLineNumber,
                    newLineNumber: line.newLineNumber,
                    ctLine: makeCTLine(line.content),
                    intralineHighlight: line.intralineHighlight
                ))
            }
        }
        invalidateSize()
    }

    private func invalidateSize() {
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    public override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: CGFloat(rows.count) * rowHeight)
    }

    // MARK: Drawing

    public override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        defer { context.restoreGState() }

        let palette = self.palette
        palette.background.nsColor.setFill()
        context.fill(dirtyRect)

        guard !rows.isEmpty else { return }

        // Visible-row clipping: convert the dirty rect's y interval into a
        // row interval. Flipped coordinates: row N spans
        // [N*rowHeight, (N+1)*rowHeight).
        let firstRow = max(Int(dirtyRect.minY / rowHeight), 0)
        let lastRow = min(Int(ceil(dirtyRect.maxY / rowHeight)), rows.count)
        guard firstRow < lastRow else { return }

        let width = bounds.width

        for index in firstRow..<lastRow {
            let row = rows[index]
            let rowTop = CGFloat(index) * rowHeight
            let baseline = baselineY(forRowTop: rowTop)
            let rowRect = NSRect(x: 0, y: rowTop, width: width, height: rowHeight)

            switch row.kind {
            case .hunkHeader:
                drawHunkHeader(row, rowRect: rowRect, baseline: baseline, palette: palette, in: context)
            case .line(let change):
                drawLine(row, change: change, rowRect: rowRect, baseline: baseline, palette: palette, in: context)
            }
        }

        drawGutterSeparators(palette: palette, in: context)
    }

    private func drawHunkHeader(
        _ row: RowRecord,
        rowRect: NSRect,
        baseline: CGFloat,
        palette: DiffPalette,
        in context: CGContext
    ) {
        palette.hunkHeaderBackground.nsColor.setFill()
        context.fill(rowRect.insetBy(dx: 0, dy: 1))
        draw(
            line: row.ctLine,
            at: gutterWidth + round(0.4 * theme.fontSize),
            baseline: baseline,
            in: context,
            color: palette.hunkHeaderText.nsColor
        )
    }

    private func drawLine(
        _ row: RowRecord,
        change: LineChange,
        rowRect: NSRect,
        baseline: CGFloat,
        palette: DiffPalette,
        in context: CGContext
    ) {
        // 1. Row background.
        switch change {
        case .addition:
            palette.addedBackground.nsColor.setFill()
            context.fill(rowRect)
        case .deletion:
            palette.deletedBackground.nsColor.setFill()
            context.fill(rowRect)
        case .context:
            break
        }

        // 2. Intra-line emphasis block (darker shade over the changed chars).
        if let highlight = row.intralineHighlight, change != .context {
            let color = (change == .addition ? palette.addedHighlight : palette.deletedHighlight).nsColor
            let startX = CTLineGetOffsetForStringIndex(row.ctLine, highlight.lowerBound, nil)
            let endX = CTLineGetOffsetForStringIndex(row.ctLine, highlight.upperBound, nil)
            if endX > startX {
                color.setFill()
                context.fill(NSRect(
                    x: contentStartX + round(startX),
                    y: rowRect.minY,
                    width: round(endX) - round(startX),
                    height: rowHeight
                ))
            }
        }

        // 3. Line numbers in the two-column gutter.
        let numberInset = round(0.5 * theme.fontSize)
        let secondary = palette.secondaryText.nsColor
        if let oldNumber = row.oldLineNumber {
            let text = oldNumber >= 100_000 ? "9999…" : String(format: "%5d", oldNumber)
            draw(
                line: makeCTLine(text),
                at: numberInset,
                baseline: baseline,
                in: context,
                color: secondary
            )
        }
        if let newNumber = row.newLineNumber {
            let text = newNumber >= 100_000 ? "9999…" : String(format: "%5d", newNumber)
            draw(
                line: makeCTLine(text),
                at: gutterColumnWidth + numberInset,
                baseline: baseline,
                in: context,
                color: secondary
            )
        }

        // 4. +/- marker.
        switch change {
        case .addition:
            draw(line: makeCTLine("+"), at: gutterWidth + 2, baseline: baseline, in: context, color: secondary)
        case .deletion:
            draw(line: makeCTLine("-"), at: gutterWidth + 2, baseline: baseline, in: context, color: secondary)
        case .context:
            break
        }

        // 5. Content.
        draw(line: row.ctLine, at: contentStartX, baseline: baseline, in: context, color: palette.text.nsColor)
    }

    private func drawGutterSeparators(palette: DiffPalette, in context: CGContext) {
        context.saveGState()
        context.setStrokeColor(palette.gutterLine.nsColor.cgColor)
        context.setLineWidth(1)
        for x in [gutterColumnWidth - 0.5, gutterWidth - 0.5] {
            context.move(to: CGPoint(x: x, y: bounds.minY))
            context.addLine(to: CGPoint(x: x, y: bounds.maxY))
        }
        context.strokePath()
        context.restoreGState()
    }
}
