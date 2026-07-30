import AppKit
import CoreText
import DiffCore

// MARK: - Renderer protocol

/// The abstraction the app layer talks to. Implementations render one file's
/// diff into an `NSView`; callers must not depend on the concrete view type,
/// so the rendering backend stays replaceable.
@MainActor
public protocol DiffRenderer: AnyObject {
    /// The file diff being displayed.
    var fileDiff: FileDiff? { get set }
    /// The view to install in the hierarchy.
    var view: NSView { get }
    /// Lays out for the given width and returns the required total height.
    func layoutHeight(forWidth width: CGFloat) -> CGFloat
}

// MARK: - Base view

/// Abstract base class for diff render views.
///
/// Owns the monospaced-font typographic metrics that make all geometry O(1):
/// every rendered row has the same fixed `rowHeight`, so "which row is at
/// point y" and "where does row N start" are single divisions. Uses a
/// flipped coordinate system so row 0 is at the top.
open class DiffRenderView: NSView {

    public var theme: DiffTheme = .default {
        didSet { rebuildFontMetrics() }
    }

    /// The palette matching the current theme and effective appearance.
    public var palette: DiffPalette {
        theme.palette(for: effectiveAppearance)
    }

    open override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    /// Vertical padding added to the font's natural line height.
    static let rowHeightPadding: CGFloat = 3

    // MARK: Typographic metrics (rebuilt when theme/font changes)

    public private(set) var font: NSFont = .monospacedSystemFont(ofSize: 12, weight: .regular)
    public private(set) var rowHeight: CGFloat = 0
    public private(set) var rowDescent: CGFloat = 0
    /// Attributes applied to all diff text.
    public private(set) var textAttributes: [NSAttributedString.Key: Any] = [:]

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        rebuildFontMetrics()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        rebuildFontMetrics()
    }

    open override var isFlipped: Bool { true }
    open override var isOpaque: Bool { true }

    private func rebuildFontMetrics() {
        font = .monospacedSystemFont(ofSize: theme.fontSize, weight: .regular)
        textAttributes = [
            .font: font,
            // Foreground color comes from the graphics context fill color at
            // draw time, so a single CTLine can be recolored without being
            // rebuilt (e.g. selection, appearance changes).
            kCTForegroundColorFromContextAttributeName as NSAttributedString.Key: true,
        ]
        let ascent = CTFontGetAscent(font)
        let descent = CTFontGetDescent(font)
        let leading = CTFontGetLeading(font)
        rowHeight = ceil(ascent + descent + leading) + Self.rowHeightPadding
        rowDescent = ceil(descent) + 1
        didRebuildFontMetrics()
        needsDisplay = true
    }

    /// Subclass hook: invalidate any cached layout that depends on metrics.
    open func didRebuildFontMetrics() {}

    /// Creates a CTLine with the standard text attributes.
    public func makeCTLine(_ string: String, bold: Bool = false) -> CTLine {
        var attributes = textAttributes
        if bold {
            attributes[.font] = NSFont.monospacedSystemFont(ofSize: theme.fontSize, weight: .semibold)
        }
        let attributed = NSAttributedString(string: string, attributes: attributes)
        return CTLineCreateWithAttributedString(attributed)
    }

    /// Baseline y-offset for text drawn inside a row whose top edge is at
    /// `rowTop` (flipped coordinates).
    public func baselineY(forRowTop rowTop: CGFloat) -> CGFloat {
        rowTop + rowHeight - rowDescent
    }

    /// Draws a CTLine at the given position in the flipped coordinate system,
    /// filled with `color`.
    public func draw(line: CTLine, at x: CGFloat, baseline y: CGFloat, in context: CGContext, color: NSColor) {
        context.saveGState()
        // In a flipped view the CTM already flips y; text must be flipped
        // back so glyphs render upright.
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        context.textPosition = CGPoint(x: x, y: y)
        context.setFillColor(color.cgColor)
        CTLineDraw(line, context)
        context.restoreGState()
    }
}
