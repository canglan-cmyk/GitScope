import Foundation
import Security

// MARK: - Models

/// A pull request summary from the GitHub API.
public struct PullRequest: Sendable, Identifiable, Equatable {
    public let number: Int
    public let title: String
    public let author: String
    public let baseRef: String
    public let headRef: String
    public let isDraft: Bool
    public let updatedAtISO8601: String
    public let additions: Int?
    public let deletions: Int?

    public var id: Int { number }

    public init(
        number: Int, title: String, author: String,
        baseRef: String, headRef: String, isDraft: Bool,
        updatedAtISO8601: String, additions: Int? = nil, deletions: Int? = nil
    ) {
        self.number = number
        self.title = title
        self.author = author
        self.baseRef = baseRef
        self.headRef = headRef
        self.isDraft = isDraft
        self.updatedAtISO8601 = updatedAtISO8601
        self.additions = additions
        self.deletions = deletions
    }
}

/// Device-flow session data shown to the user while they authorize.
public struct DeviceCodeSession: Sendable {
    public let userCode: String
    public let verificationURL: URL
    public let deviceCode: String
    public let interval: Int
    public let expiresIn: Int
}

public enum GitHubClientError: Error, LocalizedError {
    case notAuthenticated
    case httpError(status: Int, body: String)
    case deviceFlowPending
    case deviceFlowDenied
    case deviceFlowExpired
    case invalidResponse
    case noGitHubRemote

    public var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            return "尚未登录 GitHub。"
        case .httpError(let status, let body):
            return "GitHub API 请求失败（HTTP \(status)）：\(String(body.prefix(200)))"
        case .deviceFlowPending:
            return "等待用户授权中。"
        case .deviceFlowDenied:
            return "授权被拒绝。"
        case .deviceFlowExpired:
            return "授权码已过期，请重新登录。"
        case .invalidResponse:
            return "无法解析 GitHub 的响应。"
        case .noGitHubRemote:
            return "该仓库没有 GitHub remote。"
        }
    }
}

// MARK: - Client

/// Minimal GitHub API client: OAuth Device Flow authentication (token kept
/// in the Keychain) and pull-request listing. Diff content itself never
/// comes from the API — PR heads are fetched as local refs and diffed by
/// the local git engine.
public final class GitHubClient: Sendable {

    /// OAuth client ID. Device flow needs no secret, so shipping the ID in
    /// the binary is standard practice (gh CLI does the same).
    /// This is GitHub CLI's public client ID; replace with a GitScope OAuth
    /// app ID once registered.
    private let clientID: String
    private let session: URLSession

    public init(clientID: String = "178c6fc778ccc68e1d6a", session: URLSession = .shared) {
        self.clientID = clientID
        self.session = session
    }

    // MARK: Keychain-backed token

    private static let keychainService = "im.gitscope.github-token"

    public var storedToken: String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let token = String(data: data, encoding: .utf8), !token.isEmpty
        else { return nil }
        return token
    }

    public func storeToken(_ token: String) {
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecValueData as String: Data(token.utf8),
        ]
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
        ] as CFDictionary)
        SecItemAdd(attributes as CFDictionary, nil)
    }

    public func clearToken() {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
        ] as CFDictionary)
    }

    public var isAuthenticated: Bool { storedToken != nil }

    // MARK: Device flow

    /// Step 1: request a device + user code pair.
    public func startDeviceFlow() async throws -> DeviceCodeSession {
        var request = URLRequest(url: URL(string: "https://github.com/login/device/code")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("client_id=\(clientID)&scope=repo".utf8)

        let (data, response) = try await session.data(for: request)
        try Self.ensureOK(response, data: data)

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let userCode = json["user_code"] as? String,
              let verificationURI = json["verification_uri"] as? String,
              let url = URL(string: verificationURI),
              let deviceCode = json["device_code"] as? String
        else { throw GitHubClientError.invalidResponse }

        return DeviceCodeSession(
            userCode: userCode,
            verificationURL: url,
            deviceCode: deviceCode,
            interval: json["interval"] as? Int ?? 5,
            expiresIn: json["expires_in"] as? Int ?? 900
        )
    }

    /// Step 2: poll until the user authorizes (or the code expires).
    /// Returns the access token and stores it in the Keychain.
    public func waitForAuthorization(_ deviceSession: DeviceCodeSession) async throws -> String {
        let deadline = Date().addingTimeInterval(TimeInterval(deviceSession.expiresIn))
        var interval = TimeInterval(deviceSession.interval)

        while Date() < deadline {
            try Task.checkCancellation()
            try await Task.sleep(for: .seconds(interval))

            var request = URLRequest(url: URL(string: "https://github.com/login/oauth/access_token")!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(
                "client_id=\(clientID)&device_code=\(deviceSession.deviceCode)&grant_type=urn:ietf:params:oauth:grant-type:device_code".utf8
            )

            let (data, _) = try await session.data(for: request)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { throw GitHubClientError.invalidResponse }

            if let token = json["access_token"] as? String {
                storeToken(token)
                return token
            }
            switch json["error"] as? String {
            case "authorization_pending":
                continue
            case "slow_down":
                interval += 5
            case "expired_token":
                throw GitHubClientError.deviceFlowExpired
            case "access_denied":
                throw GitHubClientError.deviceFlowDenied
            default:
                throw GitHubClientError.invalidResponse
            }
        }
        throw GitHubClientError.deviceFlowExpired
    }

    // MARK: Repo discovery

    /// Extracts "owner/repo" from a git remote URL (SSH or HTTPS forms).
    public static func repoSlug(fromRemoteURL remote: String) -> String? {
        let trimmed = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        var path: Substring?
        if trimmed.hasPrefix("git@github.com:") {
            path = trimmed.dropFirst("git@github.com:".count)[...]
        } else if let range = trimmed.range(of: "github.com/") {
            path = trimmed[range.upperBound...]
        } else if trimmed.hasPrefix("ssh://git@github.com/") {
            path = trimmed.dropFirst("ssh://git@github.com/".count)[...]
        }
        guard var slug = path.map(String.init) else { return nil }
        if slug.hasSuffix(".git") { slug = String(slug.dropLast(4)) }
        let parts = slug.split(separator: "/")
        guard parts.count >= 2 else { return nil }
        return "\(parts[0])/\(parts[1])"
    }

    // MARK: Pull requests

    /// Lists open pull requests, newest-updated first.
    public func openPullRequests(slug: String, limit: Int = 50) async throws -> [PullRequest] {
        guard let token = storedToken else { throw GitHubClientError.notAuthenticated }

        var components = URLComponents(string: "https://api.github.com/repos/\(slug)/pulls")!
        components.queryItems = [
            URLQueryItem(name: "state", value: "open"),
            URLQueryItem(name: "sort", value: "updated"),
            URLQueryItem(name: "direction", value: "desc"),
            URLQueryItem(name: "per_page", value: String(limit)),
        ]

        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")

        let (data, response) = try await session.data(for: request)
        try Self.ensureOK(response, data: data)

        guard let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { throw GitHubClientError.invalidResponse }

        return array.compactMap { item in
            guard let number = item["number"] as? Int,
                  let title = item["title"] as? String,
                  let base = (item["base"] as? [String: Any])?["ref"] as? String,
                  let head = (item["head"] as? [String: Any])?["ref"] as? String
            else { return nil }
            return PullRequest(
                number: number,
                title: title,
                author: (item["user"] as? [String: Any])?["login"] as? String ?? "?",
                baseRef: base,
                headRef: head,
                isDraft: item["draft"] as? Bool ?? false,
                updatedAtISO8601: item["updated_at"] as? String ?? ""
            )
        }
    }

    /// The authenticated user's login, for showing in the UI.
    public func currentUser() async throws -> String {
        guard let token = storedToken else { throw GitHubClientError.notAuthenticated }
        var request = URLRequest(url: URL(string: "https://api.github.com/user")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        try Self.ensureOK(response, data: data)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let login = json["login"] as? String
        else { throw GitHubClientError.invalidResponse }
        return login
    }

    private static func ensureOK(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw GitHubClientError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw GitHubClientError.httpError(
                status: http.statusCode,
                body: String(data: data, encoding: .utf8) ?? ""
            )
        }
    }
}
