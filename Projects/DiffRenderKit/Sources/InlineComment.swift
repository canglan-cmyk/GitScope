import Foundation

/// A lightweight inline comment model used by the diff rendering layer.
/// The app layer maps API-specific models (e.g. PRReviewComment) into this.
public struct InlineComment: Sendable, Identifiable, Equatable {
    public let id: Int
    public let author: String
    public let body: String
    public let createdAt: String
    public let avatarURL: String?
    /// The file path this comment is attached to.
    public let path: String
    /// The diff line number this comment is attached to (new-side line number).
    public let line: Int
    /// Whether this is a reply in a thread.
    public let isReply: Bool

    public init(
        id: Int, author: String, body: String, createdAt: String,
        avatarURL: String?, path: String, line: Int, isReply: Bool = false
    ) {
        self.id = id
        self.author = author
        self.body = body
        self.createdAt = createdAt
        self.avatarURL = avatarURL
        self.path = path
        self.line = line
        self.isReply = isReply
    }

    /// Formats the createdAt ISO8601 string into a relative time string.
    public var relativeTime: String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = formatter.date(from: createdAt)
                ?? ISO8601DateFormatter().date(from: createdAt) else {
            return createdAt
        }
        let interval = -date.timeIntervalSinceNow
        if interval < 60 { return "刚刚" }
        if interval < 3600 { return "\(Int(interval / 60)) 分钟前" }
        if interval < 86400 { return "\(Int(interval / 3600)) 小时前" }
        if interval < 604800 { return "\(Int(interval / 86400)) 天前" }
        let df = DateFormatter()
        df.dateFormat = "MM/dd"
        return df.string(from: date)
    }
}
