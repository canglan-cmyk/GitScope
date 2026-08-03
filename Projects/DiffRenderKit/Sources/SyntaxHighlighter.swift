import AppKit
import CoreText

// MARK: - Syntax Highlighter

/// Lightweight regex-based syntax highlighter that produces colored
/// `NSAttributedString` for diff line content. Designed for speed over
/// completeness — covers keywords, strings, comments, numbers, and types
/// for the most common languages in iOS/web codebases.
@MainActor
public final class SyntaxHighlighter {

    public enum Language: Sendable {
        case swift
        case objc       // also covers C/C++
        case javascript // also covers TypeScript
        case python
        case ruby
        case json
        case yaml
        case css
        case html
        case shell
        case unknown
    }

    /// Determines language from a file path extension.
    public static func language(forPath path: String) -> Language {
        let ext = (path as NSString).pathExtension.lowercased()
        switch ext {
        case "swift":                          return .swift
        case "h", "m", "mm", "c", "cpp", "cc": return .objc
        case "js", "jsx", "ts", "tsx", "mjs":  return .javascript
        case "py":                             return .python
        case "rb":                             return .ruby
        case "json":                           return .json
        case "yaml", "yml":                    return .yaml
        case "css", "scss", "less":            return .css
        case "html", "htm", "xml":             return .html
        case "sh", "bash", "zsh":              return .shell
        default:                               return .unknown
        }
    }

    // MARK: Highlight colors (semantic, adapts to appearance)

    public struct Colors: Sendable {
        public let keyword: NSColor
        public let string: NSColor
        public let comment: NSColor
        public let number: NSColor
        public let type: NSColor
        public let preprocessor: NSColor

        public static let light = Colors(
            keyword: NSColor(red: 0.67, green: 0.05, blue: 0.57, alpha: 1),   // purple
            string: NSColor(red: 0.77, green: 0.10, blue: 0.09, alpha: 1),    // red
            comment: NSColor(red: 0.42, green: 0.47, blue: 0.46, alpha: 1),   // gray-green
            number: NSColor(red: 0.11, green: 0.43, blue: 0.69, alpha: 1),    // blue
            type: NSColor(red: 0.11, green: 0.43, blue: 0.69, alpha: 1),      // blue
            preprocessor: NSColor(red: 0.39, green: 0.22, blue: 0.13, alpha: 1) // brown
        )

        public static let dark = Colors(
            keyword: NSColor(red: 0.99, green: 0.37, blue: 0.53, alpha: 1),   // pink
            string: NSColor(red: 0.99, green: 0.42, blue: 0.32, alpha: 1),    // orange-red
            comment: NSColor(red: 0.42, green: 0.47, blue: 0.46, alpha: 1),   // gray-green
            number: NSColor(red: 0.82, green: 0.76, blue: 0.50, alpha: 1),    // yellow
            type: NSColor(red: 0.35, green: 0.82, blue: 0.98, alpha: 1),      // cyan
            preprocessor: NSColor(red: 0.99, green: 0.55, blue: 0.24, alpha: 1) // orange
        )
    }

    // MARK: Token types

    private enum TokenType {
        case keyword, string, comment, number, type, preprocessor
    }

    // MARK: Regex patterns per language

    private static let swiftKeywords = "\\b(func|var|let|class|struct|enum|protocol|import|return|if|else|guard|switch|case|default|for|while|repeat|break|continue|throw|throws|try|catch|async|await|actor|some|any|where|in|is|as|self|Self|super|nil|true|false|init|deinit|extension|typealias|associatedtype|private|fileprivate|internal|public|open|static|final|override|mutating|nonmutating|lazy|weak|unowned|inout|defer|do|subscript|willSet|didSet|get|set|convenience|required|optional|indirect|nonisolated|sending|consuming|borrowing|@MainActor|@Sendable|@escaping|@autoclosure|@discardableResult|@available|@objc|@Published|@State|@Binding|@Observable)\\b"

    private static let objcKeywords = "\\b(void|int|float|double|char|long|short|unsigned|signed|const|static|extern|auto|register|volatile|typedef|struct|union|enum|if|else|for|while|do|switch|case|default|break|continue|return|goto|sizeof|NULL|nil|YES|NO|true|false|self|super|id|Class|SEL|IMP|BOOL|NSInteger|NSUInteger|CGFloat|NS_ENUM|NS_OPTIONS|@interface|@implementation|@end|@property|@synthesize|@dynamic|@protocol|@class|@selector|@encode|@try|@catch|@finally|@throw|@autoreleasepool|#import|#include|#define|#ifdef|#ifndef|#endif|#pragma)\\b"

    private static let jsKeywords = "\\b(function|const|let|var|class|extends|import|export|from|return|if|else|for|while|do|switch|case|default|break|continue|throw|try|catch|finally|new|delete|typeof|instanceof|in|of|this|super|null|undefined|true|false|async|await|yield|static|get|set|constructor|interface|type|enum|implements|declare|module|namespace|abstract|readonly|as|is|keyof|infer|never|unknown|any|void|number|string|boolean|symbol|bigint)\\b"

    private static let pythonKeywords = "\\b(def|class|import|from|return|if|elif|else|for|while|break|continue|pass|raise|try|except|finally|with|as|lambda|yield|global|nonlocal|assert|del|in|is|not|and|or|True|False|None|self|async|await|match|case)\\b"

    // MARK: Public API

    /// Creates a syntax-highlighted attributed string for a diff line.
    /// Returns nil if the language is unknown (caller should fall back to plain rendering).
    public static func highlight(
        _ text: String,
        language: Language,
        font: NSFont,
        baseColor: NSColor,
        isDark: Bool
    ) -> NSAttributedString? {
        guard language != .unknown, !text.isEmpty else { return nil }

        let colors = isDark ? Colors.dark : Colors.light
        let attributed = NSMutableAttributedString(
            string: text,
            attributes: [
                .font: font,
                kCTForegroundColorFromContextAttributeName as NSAttributedString.Key: false,
                .foregroundColor: baseColor,
            ]
        )

        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)

        // 1. Comments (highest priority — overrides everything inside).
        applyPattern("//.*$|/\\*.*?\\*/", to: attributed, in: fullRange, color: colors.comment)
        applyPattern("#.*$", to: attributed, in: fullRange, color: colors.comment, languages: [.python, .shell, .yaml], current: language)

        // 2. Strings.
        applyPattern("\"(?:[^\"\\\\]|\\\\.)*\"|'(?:[^'\\\\]|\\\\.)*'", to: attributed, in: fullRange, color: colors.string)

        // 3. Numbers.
        applyPattern("\\b\\d+\\.?\\d*([eE][+-]?\\d+)?\\b|\\b0x[0-9a-fA-F]+\\b", to: attributed, in: fullRange, color: colors.number)

        // 4. Keywords (language-specific).
        let keywordPattern: String?
        switch language {
        case .swift:       keywordPattern = swiftKeywords
        case .objc:        keywordPattern = objcKeywords
        case .javascript:  keywordPattern = jsKeywords
        case .python:      keywordPattern = pythonKeywords
        default:           keywordPattern = nil
        }
        if let pattern = keywordPattern {
            applyPattern(pattern, to: attributed, in: fullRange, color: colors.keyword)
        }

        // 5. Preprocessor directives.
        if language == .objc || language == .swift {
            applyPattern("^\\s*#\\w+", to: attributed, in: fullRange, color: colors.preprocessor)
        }

        // 6. Type names (capitalized identifiers) for Swift/ObjC/JS.
        if [.swift, .objc, .javascript].contains(language) {
            applyPattern("\\b[A-Z][A-Za-z0-9_]*\\b", to: attributed, in: fullRange, color: colors.type)
        }

        return attributed
    }

    // MARK: Helpers

    private static func applyPattern(
        _ pattern: String,
        to attributed: NSMutableAttributedString,
        in range: NSRange,
        color: NSColor,
        languages: [Language]? = nil,
        current: Language? = nil
    ) {
        if let langs = languages, let cur = current, !langs.contains(cur) { return }
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else { return }
        let matches = regex.matches(in: attributed.string, options: [], range: range)
        for match in matches {
            attributed.addAttribute(.foregroundColor, value: color, range: match.range)
        }
    }
}
