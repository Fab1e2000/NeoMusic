import Foundation

struct NeteaseProfile: Codable, Equatable, Sendable {
    let userID: Int64
    let nickname: String
    let avatarURL: URL?
}

struct NeteaseCredential: Codable, Equatable, Sendable {
    let musicU: String
    let csrf: String?

    init(musicU: String, csrf: String? = nil) throws {
        guard !musicU.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NeteaseAccountError.authenticationRequired
        }
        self.musicU = musicU
        self.csrf = csrf?.isEmpty == false ? csrf : nil
    }

    init(cookies: [HTTPCookie]) throws {
        let now = Date()
        let allowed = cookies.filter {
            let domain = Self.domain($0)
            return (domain == "music.163.com" || domain == "163.com")
                && ($0.name == "MUSIC_U" || $0.name == "__csrf")
                && ($0.expiresDate.map { $0 > now } ?? true)
                && !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        func value(named name: String) -> String? {
            allowed.first { $0.name == name && Self.domain($0) == "music.163.com" }?.value
                ?? allowed.first { $0.name == name }?.value
        }
        try self.init(musicU: value(named: "MUSIC_U") ?? "", csrf: value(named: "__csrf"))
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(musicU: values.decode(String.self, forKey: .musicU),
                      csrf: values.decodeIfPresent(String.self, forKey: .csrf))
    }

    private static func domain(_ cookie: HTTPCookie) -> String {
        cookie.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
    }
}

struct NeteaseSavedSession: Codable, Equatable, Sendable {
    let profile: NeteaseProfile
    let credential: NeteaseCredential
}

enum NeteaseAccountError: Error, LocalizedError, Equatable, Sendable {
    case authenticationRequired
    case requestEncoding
    case invalidResponse
    case network(URLError.Code)
    case http(Int)
    case server(Int)
    case keychain(Int32)
    case invalidSavedSession

    var errorDescription: String? {
        switch self {
        case .authenticationRequired: "请登录网易云音乐。"
        case .requestEncoding: "无法生成网易云请求，请重试。"
        case .invalidResponse: "网易云返回的账户资料无法读取，请重试。"
        case .network: "连接网易云音乐失败，请检查网络后重试。"
        case .http(let code): "网易云音乐连接失败（HTTP \(code)），请稍后重试。"
        case .server(let code): "网易云音乐请求失败（\(code)），请稍后重试。"
        case .keychain(let status): "无法读取或保存登录凭据（\(status)），请重试。"
        case .invalidSavedSession: "保存的登录资料无法读取，请重新登录。"
        }
    }
}
