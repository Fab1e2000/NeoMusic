// EAPI framing and AES-ECB transport adapted from NeoDizzy NeteaseClient.swift
// and MeloX NeteaseDirectClient.swift (GPL-3.0), upstream commit
// 1fe5fbab3f554e8529c4847fc54281a472b7b61a: https://github.com/youshen2/MeloX
import CommonCrypto
import CryptoKit
import Foundation

@MainActor
final class NeteaseAccountClient {
    private let session: URLSession
    private let deviceID: String

    init(session: URLSession? = nil, deviceID: String = UUID().uuidString.replacingOccurrences(of: "-", with: "")) {
        self.deviceID = deviceID
        self.session = session ?? URLSession(configuration: Self.sessionConfiguration())
    }

    static func sessionConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        return configuration
    }

    func profile(credential: NeteaseCredential) async throws -> NeteaseProfile {
        try Task.checkCancellation()
        let request = try makeRequest(credential: credential)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            if Task.isCancelled || error.code == .cancelled { throw CancellationError() }
            throw NeteaseAccountError.network(error.code)
        }
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw NeteaseAccountError.invalidResponse }
        if http.statusCode == 401 { throw NeteaseAccountError.authenticationRequired }
        guard (200..<300).contains(http.statusCode) else { throw NeteaseAccountError.http(http.statusCode) }
        let envelope: AccountResponse
        do { envelope = try JSONDecoder().decode(AccountResponse.self, from: data) }
        catch { throw NeteaseAccountError.invalidResponse }
        if envelope.code == 301 || envelope.code == 401 { throw NeteaseAccountError.authenticationRequired }
        guard envelope.code == 200 else { throw NeteaseAccountError.server(envelope.code) }
        if envelope.isExplicitlySignedOut { throw NeteaseAccountError.authenticationRequired }
        guard let profile = envelope.profile else { throw NeteaseAccountError.invalidResponse }
        guard profile.userId > 0, !profile.nickname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NeteaseAccountError.invalidResponse
        }
        let avatarURL = profile.avatarUrl.flatMap { value -> URL? in
            guard var components = URLComponents(string: value),
                  ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
                  let host = components.host, !host.isEmpty else { return nil }
            components.scheme = "https"
            return components.url
        }
        return NeteaseProfile(userID: profile.userId, nickname: profile.nickname, avatarURL: avatarURL)
    }

    func makeRequest(credential: NeteaseCredential?, path: String = "/api/w/nuser/account/get", fields: [String: Any] = [:]) throws -> URLRequest {
        var header = [
            "os": "pc", "appver": "3.1.17.204416", "osver": "Microsoft-Windows-10-Professional-build-19045-64bit",
            "channel": "netease", "versioncode": "140", "mobilename": "", "resolution": "1920x1080",
            "deviceId": deviceID, "__csrf": credential?.csrf ?? "", "MUSIC_U": credential?.musicU ?? "",
            "buildver": String(Int(Date().timeIntervalSince1970))
        ]
        if credential == nil { header.removeValue(forKey: "MUSIC_U") }
        header["requestId"] = "\(Int64(Date().timeIntervalSince1970 * 1000))_\(Int.random(in: 1000...9999))"
        var payload = fields
        payload["header"] = header
        payload["e_r"] = false
        let json: String
        do { json = String(decoding: try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]), as: UTF8.self) }
        catch { throw NeteaseAccountError.requestEncoding }
        let digest = Insecure.MD5.hash(data: Data("nobody\(path)use\(json)md5forencrypt".utf8))
            .map { String(format: "%02x", $0) }.joined()
        let encrypted = try Self.encrypt(Data("\(path)-36cd479b6b5-\(json)-36cd479b6b5-\(digest)".utf8))
        var request = URLRequest(url: URL(string: "https://interface.music.163.com/eapi/" + path.dropFirst(5))!)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpShouldHandleCookies = false
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("NeteaseMusic 9.0.90/5038 (iPhone; iOS 16.2; zh_CN)", forHTTPHeaderField: "User-Agent")
        request.setValue("https://music.163.com/", forHTTPHeaderField: "Referer")
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        request.setValue(header.keys.sorted().map {
            "\($0)=\(header[$0]!.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")"
        }.joined(separator: "; "), forHTTPHeaderField: "Cookie")
        request.httpBody = Data(("params=" + encrypted.map { String(format: "%02X", $0) }.joined()).utf8)
        return request
    }

    func request(path: String, fields: [String: Any] = [:], credential: NeteaseCredential?) async throws -> Data {
        try Task.checkCancellation()
        let request = try makeRequest(credential: credential, path: path, fields: fields)
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw NeteaseAccountError.invalidResponse }
        if http.statusCode == 401 { throw NeteaseAccountError.authenticationRequired }
        guard (200..<300).contains(http.statusCode) else { throw NeteaseAccountError.http(http.statusCode) }
        struct Status: Decodable { let code: Int }
        let status = try JSONDecoder().decode(Status.self, from: data)
        if status.code == 301 || status.code == 401 { throw NeteaseAccountError.authenticationRequired }
        guard status.code == 200 else { throw NeteaseAccountError.server(status.code) }
        return data
    }

    private static func encrypt(_ data: Data) throws -> Data {
        let key = "e82ckenh8dichen8"
        var output = Data(count: data.count + kCCBlockSizeAES128)
        let capacity = output.count
        var length = 0
        let status = output.withUnsafeMutableBytes { destination in
            data.withUnsafeBytes { source in
                key.withCString { key in
                    CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding | kCCOptionECBMode), key, kCCKeySizeAES128, nil,
                            source.baseAddress, data.count, destination.baseAddress, capacity, &length)
                }
            }
        }
        guard status == kCCSuccess else { throw NeteaseAccountError.requestEncoding }
        output.count = length
        return output
    }

    private struct AccountResponse: Decodable {
        let code: Int
        let profile: Profile?
        let isExplicitlySignedOut: Bool

        private enum CodingKeys: String, CodingKey { case code, account, profile }

        init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            code = try values.decode(Int.self, forKey: .code)
            guard code == 200 else {
                profile = nil
                isExplicitlySignedOut = false
                return
            }
            profile = try values.decodeIfPresent(Profile.self, forKey: .profile)
            if values.contains(.account), values.contains(.profile) {
                isExplicitlySignedOut = try values.decodeNil(forKey: .account) && values.decodeNil(forKey: .profile)
            } else {
                isExplicitlySignedOut = false
            }
        }

        struct Profile: Decodable {
            let userId: Int64
            let nickname: String
            let avatarUrl: String?
        }
    }
}
