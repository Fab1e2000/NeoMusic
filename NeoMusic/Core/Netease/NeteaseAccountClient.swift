// and MeloX NeteaseDirectClient.swift (GPL-3.0), upstream commit
import CommonCrypto
import CryptoKit
import Foundation
import Security

final class NeteaseAccountClient: Sendable {
    enum EAPIProfile: Sendable { case account, playback, search }
    private let session: URLSession
    private let deviceID: String
    private let sessionCookies = SessionCookies()

    private struct PreparedRequest {
        let request: URLRequest
        let cookieStorage: HTTPCookieStorage?
        let sessionCookie: HTTPCookie?
    }

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

    @concurrent func profile(credential: NeteaseCredential) async throws -> NeteaseProfile {
        try Task.checkCancellation()
        let request = try prepareEAPIRequest(credential: credential)
        let data: Data
        do {
            data = try await validatedData(for: request, retryTLS: true)
        } catch let error as URLError {
            if Task.isCancelled || error.code == .cancelled { throw CancellationError() }
            throw NeteaseAccountError.network(error.code)
        }
        let envelope: AccountResponse
        do { envelope = try JSONDecoder().decode(AccountResponse.self, from: data) }
        catch {
            AppLogger.account.error("transport.profile.decode_failed")
            throw NeteaseAccountError.invalidResponse
        }
        try Self.validateCode(envelope.code) { NeteaseAccountError.server(envelope.code) }
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

    func makeRequest(credential: NeteaseCredential?, path: String = "/api/w/nuser/account/get", fields: [String: any Sendable] = [:], profile: EAPIProfile = .account) throws -> URLRequest {
        try prepareEAPIRequest(credential: credential, path: path, fields: fields, profile: profile).request
    }

    private func prepareEAPIRequest(credential: NeteaseCredential?, path: String = "/api/w/nuser/account/get",
                                    fields: [String: any Sendable] = [:], profile: EAPIProfile = .account) throws -> PreparedRequest {
        let url = URL(string: "https://interface.music.163.com/eapi/" + path.dropFirst(5))!
        let (storage, cookie) = sessionCookies.snapshot(for: credential, url: url)
        let timestamp = Date().timeIntervalSince1970
        let requestSuffix = profile == .account ? String(Int.random(in: 1000...9999)) : "0000"
        let appVersion = "9.0.90", osVersion = "18.0"
        var header = ["os": "ios", "appver": appVersion, "osver": osVersion,
                      "buildver": String(Int(timestamp)), "channel": "distribution",
                      "__csrf": credential?.csrf ?? "",
                      "requestId": "\(Int64(timestamp * 1000))_\(requestSuffix)"]
        if profile == .account { header["deviceId"] = deviceID }
        if let credential { header["MUSIC_U"] = credential.musicU }
        let cookies: [String: String]
        if profile == .account {
            cookies = header
        } else {
            var values = ["os": "ios", "appver": appVersion, "__remember_me": "true"]
            if let credential {
                values["MUSIC_U"] = credential.musicU
                if let csrf = credential.csrf { values["__csrf"] = csrf }
            }
            cookies = values
        }
        if let cookie { header[cookie.name] = cookie.value }
        var payload = fields
        payload["header"] = header
        payload["e_r"] = false
        let json: String
        do { json = String(decoding: try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]), as: UTF8.self) }
        catch { throw NeteaseAccountError.requestEncoding }
        let digest = Insecure.MD5.hash(data: Data("nobody\(path)use\(json)md5forencrypt".utf8))
            .map { String(format: "%02x", $0) }.joined()
        let encrypted = try Self.encrypt(Data("\(path)-36cd479b6b5-\(json)-36cd479b6b5-\(digest)".utf8))
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpShouldHandleCookies = false
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(profile != .account
            ? "Mozilla/5.0 (iPhone; CPU iPhone OS \(osVersion.replacingOccurrences(of: ".", with: "_")) like Mac OS X) AppleWebKit/605.1.15 Mobile/15E148"
            : "NeteaseMusic \(appVersion)/5038 (iPhone; iOS \(osVersion); zh_CN)", forHTTPHeaderField: "User-Agent")
        if profile == .account { request.setValue("https://music.163.com/", forHTTPHeaderField: "Referer") }
        request.setValue(Self.cookieHeader(fields: cookies, sessionCookie: cookie), forHTTPHeaderField: "Cookie")
        request.httpBody = Data(("params=" + encrypted.map { String(format: "%02X", $0) }.joined()).utf8)
        return PreparedRequest(request: request, cookieStorage: storage, sessionCookie: cookie)
    }

    @concurrent func request(path: String, fields: [String: any Sendable] = [:], credential: NeteaseCredential?, profile: EAPIProfile = .account, retryTLS: Bool = false) async throws -> Data {
        let data = try await responseData(path: path, fields: fields, credential: credential, profile: profile, retryTLS: retryTLS)
        do { _ = try JSONDecoder().decode(CheckedResponse<EmptyResponse>.self, from: data) }
        catch is DecodingError {
            AppLogger.account.error("transport.response.decode_failed")
            throw NeteaseAccountError.invalidResponse
        }
        return data
    }

    @concurrent func decoded<Response: Decodable & Sendable>(path: String, fields: [String: any Sendable], credential: NeteaseCredential?, profile: EAPIProfile = .account, retryTLS: Bool = false) async throws -> Response {
        let data = try await responseData(path: path, fields: fields, credential: credential, profile: profile, retryTLS: retryTLS)
        let response: Response
        do { response = try JSONDecoder().decode(CheckedResponse<Response>.self, from: data).value }
        catch is DecodingError {
            AppLogger.account.error("transport.response.decode_failed")
            throw NeteaseAccountError.invalidResponse
        }
        try Task.checkCancellation()
        return response
    }

    private func responseData(path: String, fields: [String: any Sendable], credential: NeteaseCredential?, profile: EAPIProfile, retryTLS: Bool) async throws -> Data {
        try Task.checkCancellation()
        let request = try prepareEAPIRequest(credential: credential, path: path, fields: fields, profile: profile)
        return try await validatedData(for: request, retryTLS: retryTLS || profile == .playback)
    }

    private func validatedData(for request: PreparedRequest, retryTLS: Bool) async throws -> Data {
        let (data, response): (Data, URLResponse)
        do { (data, response) = try await dataWithTLSRetry(for: request, enabled: retryTLS) }
        catch {
            AppLogger.failure(AppLogger.account, "transport.request.failed", error: error)
            throw error
        }
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else {
            AppLogger.account.error("transport.response.non_http")
            throw NeteaseAccountError.invalidResponse
        }
        if !(200..<300).contains(http.statusCode) {
            AppLogger.account.error("transport.response.rejected status=\(http.statusCode)")
            if http.statusCode == 401 { throw NeteaseAccountError.authenticationRequired }
            throw NeteaseAccountError.http(http.statusCode)
        }
        return data
    }

    private func dataWithTLSRetry(for prepared: PreparedRequest, enabled: Bool) async throws -> (Data, URLResponse) {
        try Task.checkCancellation()
        let request = prepared.request
        let redirects: CookieScopedRedirects?
        if let cookie = prepared.sessionCookie, let storage = prepared.cookieStorage {
            redirects = CookieScopedRedirects(cookie: cookie, storage: storage)
        } else {
            redirects = nil
        }
        let result: (Data, URLResponse)
        do {
            result = try await session.data(for: request, delegate: redirects)
        } catch let error as URLError where enabled && error.code == .secureConnectionFailed {
            try Task.checkCancellation()
            AppLogger.account.notice("transport.tls.retry code=\(error.code.rawValue)")
            result = try await session.data(for: request, delegate: redirects)
        }
        try Task.checkCancellation()
        if let response = result.1 as? HTTPURLResponse, let storage = prepared.cookieStorage,
           Self.sameOrigin(request.url, response.url) {
            sessionCookies.accept(response, in: storage)
        }
        return result
    }

    func clearSessionCookies(for credential: NeteaseCredential) {
        sessionCookies.clear(for: credential)
    }

    private static func sameOrigin(_ source: URL?, _ target: URL?) -> Bool {
        guard let source, let target, source.scheme == "https", target.scheme == "https",
              let host = source.host else { return false }
        return host.lowercased() == target.host?.lowercased() && (source.port ?? 443) == (target.port ?? 443)
    }

    private final class CookieScopedRedirects: NSObject, URLSessionTaskDelegate {
        private let cookie: HTTPCookie
        private let storage: HTTPCookieStorage

        init(cookie: HTTPCookie, storage: HTTPCookieStorage) {
            self.cookie = cookie
            self.storage = storage
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? {
            guard let url = request.url, NeteaseAccountClient.sameOrigin(response.url, url) else { return nil }
            return storage.cookies(for: url)?.contains(where: {
                $0.name == cookie.name && $0.domain == cookie.domain && $0.path == cookie.path && $0.value == cookie.value
            }) == true ? request : nil
        }
    }

    private static func cookieHeader(fields: [String: String], sessionCookie: HTTPCookie?) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        var pairs = fields.sorted { $0.key < $1.key }.map { name, value in
            "\(name)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")"
        }
        if let sessionCookie, let pair = HTTPCookie.requestHeaderFields(with: [sessionCookie])["Cookie"] {
            pairs.append(pair)
        }
        return pairs.joined(separator: "; ")
    }

    private static func randomHex(byteCount: Int) -> String {
        let alphabet = Array("0123456789abcdef".utf8)
        var generator = SystemRandomNumberGenerator()
        return String(decoding: (0..<(byteCount * 2)).map { _ in alphabet.randomElement(using: &generator)! }, as: UTF8.self)
    }

    private final class SessionCookies: @unchecked Sendable {
        private let lock = NSLock()
        private var jars: [SHA256.Digest?: HTTPCookieStorage] = [:]

        func snapshot(for credential: NeteaseCredential?, url: URL) -> (HTTPCookieStorage?, HTTPCookie?) {
            let key = credential.map { SHA256.hash(data: Data($0.musicU.utf8)) }
            return lock.withLock {
                let jar = jars[key] ?? URLSessionConfiguration.ephemeral.httpCookieStorage
                jars[key] = jar
                let cookie = jar?.cookies(for: url)?.first { $0.name == "NMTID" }
                return (jar, cookie)
            }
        }

        func accept(_ response: HTTPURLResponse, in jar: HTTPCookieStorage) {
            guard let url = response.url, let host = url.host?.lowercased(),
                  let value = response.value(forHTTPHeaderField: "Set-Cookie") else { return }
            let cookies = HTTPCookie.cookies(withResponseHeaderFields: ["Set-Cookie": value], for: url).filter { cookie in
                let domain = cookie.domain.lowercased()
                let isProviderDomain = domain.hasPrefix(".") && domain.hasSuffix(".163.com")
                let matchesDomain = isProviderDomain && (host == domain.dropFirst() || host.hasSuffix(domain))
                return cookie.name == "NMTID" && (domain == host || matchesDomain)
            }
            lock.withLock {
                for cookie in cookies {
                    if cookie.value.isEmpty || cookie.expiresDate.map({ $0 <= Date() }) == true {
                        for existing in jar.cookies ?? []
                            where existing.name == cookie.name && existing.domain == cookie.domain && existing.path == cookie.path {
                            jar.deleteCookie(existing)
                        }
                    } else {
                        jar.setCookies([cookie], for: url, mainDocumentURL: url)
                    }
                }
            }
        }

        func clear(for credential: NeteaseCredential) {
            let key = SHA256.hash(data: Data(credential.musicU.utf8))
            lock.withLock { _ = jars.removeValue(forKey: key) }
        }
    }

    private static func validateCode(_ code: Int, requiresAuthenticationFor301: Bool = true,
                                     failure: () throws -> any Error) throws {
        guard code != 200 else { return }
        let needsAuthentication = code == 401 || (code == 301 && requiresAuthenticationFor301)
        AppLogger.account.error("transport.business.rejected code=\(code)")
        if needsAuthentication { throw NeteaseAccountError.authenticationRequired }
        throw try failure()
    }

    private struct EmptyResponse: Decodable {}
    private struct CheckedResponse<Value: Decodable>: Decodable {
        let value: Value
        private enum CodingKeys: String, CodingKey { case code }
        init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            let code = try values.decode(Int.self, forKey: .code)
            try NeteaseAccountClient.validateCode(code) { NeteaseAccountError.server(code) }
            value = try Value(from: decoder)
        }
    }

    /*
    The MIT License (MIT)

    Copyright (c) 2013-2022 Binaryify

    Permission is hereby granted, free of charge, to any person obtaining a copy
    of this software and associated documentation files (the "Software"), to deal
    in the Software without restriction, including without limitation the rights
    to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
    copies of the Software, and to permit persons to whom the Software is
    furnished to do so, subject to the following conditions:

    The above copyright notice and this permission notice shall be included in
    all copies or substantial portions of the Software.

    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
    IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
    FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
    AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
    LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
    OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
    THE SOFTWARE.
    */
    func makeWebRequest(path: String, fields: [String: any Sendable], credential: NeteaseCredential?) throws -> URLRequest {
        try prepareWebRequest(path: path, fields: fields, credential: credential).request
    }

    private func prepareWebRequest(path: String, fields: [String: any Sendable],
                                   credential: NeteaseCredential?) throws -> PreparedRequest {
        var payload = fields
        payload["csrf_token"] = credential?.csrf ?? ""
        let json = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789".utf8)
        var generator = SystemRandomNumberGenerator()
        let secret = Data((0..<16).map { _ in alphabet.randomElement(using: &generator)! })
        let first = try Self.encryptCBC(json, key: Data("0CoJUm6Qyw8W8jud".utf8)).base64EncodedString()
        let params = try Self.encryptCBC(Data(first.utf8), key: secret).base64EncodedString()
        let spki = Data(base64Encoded: "MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQDgtQn2JZ34ZC28NWYpAUd98iZ37BUrX/aKzmFbt7clFSs6sXqHauqKWqdtLkF2KexO40H1YTX8z2lSgBBOAxLsvaklV8k4cBFK9snQXE9/DDaFt6Rr7iVZMldczhC0JNgTz+SHXT6CBHuX3e9SdB1Ua44oncaTWz7OBGLbCiK45wIDAQAB")!
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(spki.dropFirst(22) as CFData, [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPublic] as CFDictionary, &error) else { throw NeteaseAccountError.requestEncoding }
        let block = Data(repeating: 0, count: 112) + Data(secret.reversed())
        guard let encrypted = SecKeyCreateEncryptedData(key, .rsaEncryptionRaw, block as CFData, &error) as Data? else { throw NeteaseAccountError.requestEncoding }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let encoded = params.addingPercentEncoding(withAllowedCharacters: allowed)!
        let rsa = encrypted.map { String(format: "%02x", $0) }.joined()
        let url = URL(string: "https://music.163.com/weapi/" + path.dropFirst(5))!
        let (storage, cookie) = sessionCookies.snapshot(for: credential, url: url)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.httpShouldHandleCookies = false
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("https://music.163.com", forHTTPHeaderField: "Origin")
        request.setValue("https://music.163.com", forHTTPHeaderField: "Referer")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        // Web client profile adapted from NeoDizzy NeteaseClient.makeWebRequest (GPL-3.0).
        // Same browser/device cookie profile NeteaseCloudMusicApiEnhanced applies to weapi
        // requests in util/request.js; web endpoints answer with an empty body or a refusal
        // when only MUSIC_U is forwarded.
        let timestamp = Int64(Date().timeIntervalSince1970 * 1000)
        var cookies = ["__csrf": credential?.csrf ?? "",
                       "os": "pc", "appver": "3.1.17.204416",
                       "osver": "Microsoft-Windows-10-Professional-build-19045-64bit", "channel": "netease",
                       "deviceId": deviceID, "__remember_me": "true", "ntes_kaola_ad": "1",
                       "_ntes_nuid": deviceID, "_ntes_nnid": "\(deviceID),\(timestamp)", "WEVNSM": "1.0.0",
                       "WNMCID": "\(deviceID.prefix(6)).\(timestamp).01.0"]
        if let credential { cookies["MUSIC_U"] = credential.musicU }
        if cookie == nil { cookies["NMTID"] = "00O" + Self.randomHex(byteCount: 19) }
        request.setValue(Self.cookieHeader(fields: cookies, sessionCookie: cookie), forHTTPHeaderField: "Cookie")
        request.httpBody = Data("params=\(encoded)&encSecKey=\(rsa)".utf8)
        return PreparedRequest(request: request, cookieStorage: storage, sessionCookie: cookie)
    }
    @concurrent func requestWeb(path: String, fields: [String: any Sendable], credential: NeteaseCredential?, retryTLS: Bool = false) async throws -> Data {
        try Task.checkCancellation()
        let request = try prepareWebRequest(path: path, fields: fields, credential: credential)
        let data = try await validatedData(for: request, retryTLS: retryTLS)
        do { _ = try JSONDecoder().decode(CheckedWebResponse.self, from: data) }
        catch is DecodingError {
            AppLogger.account.error("transport.response.decode_failed")
            throw NeteaseAccountError.invalidResponse
        }
        return data
    }

    private struct CheckedWebResponse: Decodable {
        private enum CodingKeys: String, CodingKey { case code, message, msg }

        init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            let code = try values.decode(Int.self, forKey: .code)
            func messages() throws -> (primary: String?, fallback: String?) {
                try (values.decodeIfPresent(String.self, forKey: .message),
                     values.decodeIfPresent(String.self, forKey: .msg))
            }
            try NeteaseAccountClient.validateCode(code, requiresAuthenticationFor301: false) {
                let (primary, fallback) = try messages()
                if code == 301 {
                    // WEAPI also uses 301 for business rejections, including subscription writes.
                    guard let reason = [primary, fallback].compactMap({ $0 }).first(where: Self.isBusinessMessage) else {
                        return NeteaseAccountError.authenticationRequired
                    }
                    return NeteaseWebResponseError(code: code, message: reason)
                }
                return NeteaseWebResponseError(code: code, message: primary ?? fallback)
            }
            _ = try messages()
        }

        private static func isBusinessMessage(_ message: String) -> Bool {
            let normalized = message.trimmingCharacters(in: .whitespacesAndNewlines.union(.init(charactersIn: ".。!！")))
                .replacingOccurrences(of: "登陆", with: "登录")
                .lowercased()
            switch normalized {
            case "", "未登录", "用户未登录", "需要登录", "请登录", "请先登录", "请重新登录",
                 "请登录网易云音乐", "请先登录网易云音乐", "请登录后重试", "登录失效", "登录已失效", "登录过期", "登录已过期",
                 "login required", "not logged in", "please log in", "please login", "please log in again",
                 "login expired", "session expired":
                return false
            default:
                return true
            }
        }
    }

    private static func encryptCBC(_ data: Data, key: Data) throws -> Data {
        var output = Data(count: data.count + kCCBlockSizeAES128)
        let capacity = output.count
        var length = 0
        let status = output.withUnsafeMutableBytes { destination in
            data.withUnsafeBytes { source in
                key.withUnsafeBytes { keyBytes in
                    "0102030405060708".withCString { iv in
                        CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding), keyBytes.baseAddress, key.count, iv, source.baseAddress, data.count, destination.baseAddress, capacity, &length)
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw NeteaseAccountError.requestEncoding }
        output.count = length
        return output
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

struct NeteaseWebResponseError: LocalizedError, Equatable, Sendable {
    let code: Int
    let message: String?
    var errorDescription: String? {
        if let message, !message.isEmpty { return "\(message)（\(code)）" }
        return "网易云音乐请求失败（\(code)），请稍后重试。"
    }
}
