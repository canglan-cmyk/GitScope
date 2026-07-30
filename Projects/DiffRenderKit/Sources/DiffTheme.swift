import AppKit

// MARK: - Palette

/// A concrete set of colors for diff rendering. Colors are plain values so
/// a palette is fully `Sendable`; adaptive (light/dark) themes are expressed
/// by giving the theme two palettes.
public struct DiffPalette: Sendable {
    public var background: ColorValue
    public var text: ColorValue
    public var secondaryText: ColorValue
    public var addedBackground: ColorValue
    public var deletedBackground: ColorValue
    public var addedHighlight: ColorValue
    public var deletedHighlight: ColorValue
    public var hunkHeaderBackground: ColorValue
    public var hunkHeaderText: ColorValue
    public var gutterLine: ColorValue

    /// sRGB color value, kept as raw components for Sendable-ness.
    public struct ColorValue: Sendable {
        public var red: Double
        public var green: Double
        public var blue: Double
        public var alpha: Double

        public init(_ red: Double, _ green: Double, _ blue: Double, _ alpha: Double = 1) {
            self.red = red
            self.green = green
            self.blue = blue
            self.alpha = alpha
        }

        /// Hex convenience, e.g. `ColorValue(hex: 0xE6FFEC)`.
        public init(hex: UInt32, alpha: Double = 1) {
            self.init(
                Double((hex >> 16) & 0xFF) / 255,
                Double((hex >> 8) & 0xFF) / 255,
                Double(hex & 0xFF) / 255,
                alpha
            )
        }

        public var nsColor: NSColor {
            NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
        }
    }
}

// MARK: - Theme

/// A diff theme: an identity plus light and dark palettes. The effective
/// palette is chosen from the view's appearance at draw time.
public struct DiffTheme: Sendable, Identifiable {
    public var id: String
    /// Display name, localized at the call site.
    public var name: String
    public var fontSize: CGFloat
    public var light: DiffPalette
    public var dark: DiffPalette

    public init(
        id: String,
        name: String,
        fontSize: CGFloat = 12,
        light: DiffPalette,
        dark: DiffPalette
    ) {
        self.id = id
        self.name = name
        self.fontSize = fontSize
        self.light = light
        self.dark = dark
    }

    /// Resolves the palette for an appearance.
    public func palette(for appearance: NSAppearance?) -> DiffPalette {
        let isDark = appearance?.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return isDark ? dark : light
    }
}

// MARK: - Built-in themes

extension DiffTheme {

    /// All built-in themes, in menu order.
    public static let builtIn: [DiffTheme] = [.github, .classic, .solarized, .colorblind]

    public static let `default` = DiffTheme.github

    /// GitHub 风格:网页版同款红绿。
    public static let github = DiffTheme(
        id: "github",
        name: "GitHub",
        light: DiffPalette(
            background: .init(hex: 0xFFFFFF),
            text: .init(hex: 0x1F2328),
            secondaryText: .init(hex: 0x636C76),
            addedBackground: .init(hex: 0xE6FFEC),
            deletedBackground: .init(hex: 0xFFEBE9),
            addedHighlight: .init(hex: 0xABF2BC),
            deletedHighlight: .init(0.98, 0.71, 0.70, 1),
            hunkHeaderBackground: .init(hex: 0xDDF4FF),
            hunkHeaderText: .init(hex: 0x57606A),
            gutterLine: .init(hex: 0xD8DEE4)
        ),
        dark: DiffPalette(
            background: .init(hex: 0x0D1117),
            text: .init(hex: 0xE6EDF3),
            secondaryText: .init(hex: 0x7D8590),
            addedBackground: .init(hex: 0x2EA043, alpha: 0.15),
            deletedBackground: .init(hex: 0xF85149, alpha: 0.15),
            addedHighlight: .init(hex: 0x2EA043, alpha: 0.4),
            deletedHighlight: .init(hex: 0xF85149, alpha: 0.4),
            hunkHeaderBackground: .init(hex: 0x388BFD, alpha: 0.15),
            hunkHeaderText: .init(hex: 0x7D8590),
            gutterLine: .init(hex: 0x30363D)
        )
    )

    /// 经典红绿:高饱和传统终端风。
    public static let classic = DiffTheme(
        id: "classic",
        name: "Classic",
        light: DiffPalette(
            background: .init(hex: 0xFFFFFF),
            text: .init(hex: 0x000000),
            secondaryText: .init(hex: 0x808080),
            addedBackground: .init(hex: 0xDDFFDD),
            deletedBackground: .init(hex: 0xFFDDDD),
            addedHighlight: .init(hex: 0x99EE99),
            deletedHighlight: .init(hex: 0xFF9999),
            hunkHeaderBackground: .init(hex: 0xEEEEEE),
            hunkHeaderText: .init(hex: 0x666666),
            gutterLine: .init(hex: 0xDDDDDD)
        ),
        dark: DiffPalette(
            background: .init(hex: 0x1E1E1E),
            text: .init(hex: 0xD4D4D4),
            secondaryText: .init(hex: 0x7F7F7F),
            addedBackground: .init(hex: 0x1C3320),
            deletedBackground: .init(hex: 0x3A1D1D),
            addedHighlight: .init(hex: 0x2F5D36),
            deletedHighlight: .init(hex: 0x6B2E2E),
            hunkHeaderBackground: .init(hex: 0x2D2D2D),
            hunkHeaderText: .init(hex: 0x9F9F9F),
            gutterLine: .init(hex: 0x3C3C3C)
        )
    )

    /// Solarized:Ethan Schoonover 经典配色。
    public static let solarized = DiffTheme(
        id: "solarized",
        name: "Solarized",
        light: DiffPalette(
            background: .init(hex: 0xFDF6E3),
            text: .init(hex: 0x657B83),
            secondaryText: .init(hex: 0x93A1A1),
            addedBackground: .init(hex: 0x859900, alpha: 0.12),
            deletedBackground: .init(hex: 0xDC322F, alpha: 0.12),
            addedHighlight: .init(hex: 0x859900, alpha: 0.35),
            deletedHighlight: .init(hex: 0xDC322F, alpha: 0.35),
            hunkHeaderBackground: .init(hex: 0xEEE8D5),
            hunkHeaderText: .init(hex: 0x93A1A1),
            gutterLine: .init(hex: 0xEEE8D5)
        ),
        dark: DiffPalette(
            background: .init(hex: 0x002B36),
            text: .init(hex: 0x839496),
            secondaryText: .init(hex: 0x586E75),
            addedBackground: .init(hex: 0x859900, alpha: 0.18),
            deletedBackground: .init(hex: 0xDC322F, alpha: 0.18),
            addedHighlight: .init(hex: 0x859900, alpha: 0.45),
            deletedHighlight: .init(hex: 0xDC322F, alpha: 0.45),
            hunkHeaderBackground: .init(hex: 0x073642),
            hunkHeaderText: .init(hex: 0x586E75),
            gutterLine: .init(hex: 0x073642)
        )
    )

    /// 色盲友好:蓝/橙对比替代红/绿(deuteranopia-safe)。
    public static let colorblind = DiffTheme(
        id: "colorblind",
        name: "Colorblind Safe",
        light: DiffPalette(
            background: .init(hex: 0xFFFFFF),
            text: .init(hex: 0x1F2328),
            secondaryText: .init(hex: 0x636C76),
            addedBackground: .init(hex: 0xDDEBFF),
            deletedBackground: .init(hex: 0xFFE8D1),
            addedHighlight: .init(hex: 0xA5CFFF),
            deletedHighlight: .init(hex: 0xFFC680),
            hunkHeaderBackground: .init(hex: 0xF0F0F0),
            hunkHeaderText: .init(hex: 0x57606A),
            gutterLine: .init(hex: 0xD8DEE4)
        ),
        dark: DiffPalette(
            background: .init(hex: 0x0D1117),
            text: .init(hex: 0xE6EDF3),
            secondaryText: .init(hex: 0x7D8590),
            addedBackground: .init(hex: 0x1F4B8E, alpha: 0.35),
            deletedBackground: .init(hex: 0x8E5A1F, alpha: 0.35),
            addedHighlight: .init(hex: 0x2F6FD0, alpha: 0.55),
            deletedHighlight: .init(hex: 0xD08A2F, alpha: 0.55),
            hunkHeaderBackground: .init(hex: 0x21262D),
            hunkHeaderText: .init(hex: 0x7D8590),
            gutterLine: .init(hex: 0x30363D)
        )
    )
}
