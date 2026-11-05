// EAPI framing and AES-ECB transport adapted from NeoDizzy NeteaseClient.swift
// and MeloX NeteaseDirectClient.swift (GPL-3.0), upstream commit
// 1fe5fbab3f554e8529c4847fc54281a472b7b61a: https://github.com/youshen2/MeloX
import CommonCrypto
import CryptoKit
import Foundation
import Security

final class NeteaseAccountClient: Sendable {
    enum EAPIProfile: Sendable { case account, playback }
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

    @concurrent func profile(credential: NeteaseCredential) async throws -> NeteaseProfile {
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

    func makeRequest(credential: NeteaseCredential?, path: String = "/api/w/nuser/account/get", fields: [String: any Sendable] = [:], profile: EAPIProfile = .account) throws -> URLRequest {
        var header = [
            "os": "pc", "appver": "3.1.17.204416", "osver": "Microsoft-Windows-10-Professional-build-19045-64bit",
            "channel": "netease", "versioncode": "140", "mobilename": "", "resolution": "1920x1080",
            "deviceId": deviceID, "__csrf": credential?.csrf ?? "", "MUSIC_U": credential?.musicU ?? "",
            "buildver": String(Int(Date().timeIntervalSince1970))
        ]
        if credential == nil { header.removeValue(forKey: "MUSIC_U") }
        header["requestId"] = "\(Int64(Date().timeIntervalSince1970 * 1000))_\(Int.random(in: 1000...9999))"
        // MeloX 09713ed: song_url_v1 uses the default iOS EAPI profile,
        // with MUSIC_U in both the encrypted header and the scoped cookie.
        if profile == .playback {
            header = ["os": "ios", "appver": "9.0.90", "osver": "18.0",
                      "buildver": String(Int(Date().timeIntervalSince1970)),
                      "channel": "distribution", "__csrf": credential?.csrf ?? "",
                      "requestId": "\(Int64(Date().timeIntervalSince1970 * 1000))_0000"]
            if let credential { header["MUSIC_U"] = credential.musicU }
        }
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
        request.setValue(profile == .playback
            ? "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 Mobile/15E148"
            : "NeteaseMusic 9.0.90/5038 (iPhone; iOS 16.2; zh_CN)", forHTTPHeaderField: "User-Agent")
        if profile == .account { request.setValue("https://music.163.com/", forHTTPHeaderField: "Referer") }
        let cookies: [String: String]
        if profile == .playback {
            var values = ["os": "ios", "appver": "9.0.90", "__remember_me": "true"]
            if let credential {
                values["MUSIC_U"] = credential.musicU
                if let csrf = credential.csrf { values["__csrf"] = csrf }
            }
            cookies = values
        } else { cookies = header }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        request.setValue(cookies.keys.sorted().map {
            "\($0)=\(cookies[$0]!.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")"
        }.joined(separator: "; "), forHTTPHeaderField: "Cookie")
        request.httpBody = Data(("params=" + encrypted.map { String(format: "%02X", $0) }.joined()).utf8)
        return request
    }

    @concurrent func request(path: String, fields: [String: any Sendable] = [:], credential: NeteaseCredential?, profile: EAPIProfile = .account) async throws -> Data {
        let data = try await responseData(path: path, fields: fields, credential: credential, profile: profile)
        _ = try JSONDecoder().decode(CheckedResponse<EmptyResponse>.self, from: data)
        return data
    }

    @concurrent func decoded<Response: Decodable & Sendable>(path: String, fields: [String: any Sendable], credential: NeteaseCredential?, profile: EAPIProfile = .account) async throws -> Response {
        let data = try await responseData(path: path, fields: fields, credential: credential, profile: profile)
        let response = try JSONDecoder().decode(CheckedResponse<Response>.self, from: data).value
        try Task.checkCancellation()
        return response
    }

    private func responseData(path: String, fields: [String: any Sendable], credential: NeteaseCredential?, profile: EAPIProfile) async throws -> Data {
        try Task.checkCancellation()
        let request = try makeRequest(credential: credential, path: path, fields: fields, profile: profile)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where profile == .playback && error.code == .secureConnectionFailed {
            // The read-only playback POST can recover from the observed transient
            // TLS handshake failure on a new task. Keep system trust evaluation,
            // allow one retry, and never retry account writes or server rejections.
            try Task.checkCancellation()
            (data, response) = try await session.data(for: makeRequest(
                credential: credential, path: path, fields: fields, profile: profile))
        }
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw NeteaseAccountError.invalidResponse }
        if http.statusCode == 401 { throw NeteaseAccountError.authenticationRequired }
        guard (200..<300).contains(http.statusCode) else { throw NeteaseAccountError.http(http.statusCode) }
        return data
    }

    private struct EmptyResponse: Decodable {}
    private struct CheckedResponse<Value: Decodable>: Decodable {
        let value: Value
        private enum CodingKeys: String, CodingKey { case code }
        init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            let code = try values.decode(Int.self, forKey: .code)
            if code == 301 || code == 401 { throw NeteaseAccountError.authenticationRequired }
            guard code == 200 else { throw NeteaseAccountError.server(code) }
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
    // WEAPI wire format follows api-enhanced util/crypto.js (MIT, Binaryify).
    // Native CommonCrypto CBC and Security RSA implement the protocol without a JS dependency.
    func makeWebRequest(path: String, fields: [String: any Sendable], credential: NeteaseCredential) throws -> URLRequest {
        var payload = fields
        payload["csrf_token"] = credential.csrf ?? ""
        let json = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789".utf8)
        var generator = SystemRandomNumberGenerator()
        let secret = Data((0..<16).map { _ in alphabet.randomElement(using: &generator)! })
        let first = try Self.encryptCBC(json, key: Data("0CoJUm6Qyw8W8jud".utf8)).base64EncodedString()
        let params = try Self.encryptCBC(Data(first.utf8), key: secret).base64EncodedString()
        // PKCS#1 DER public key: 1024-bit service modulus and exponent 65537.
        let spki = Data(base64Encoded: "MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQDgtQn2JZ34ZC28NWYpAUd98iZ37BUrX/aKzmFbt7clFSs6sXqHauqKWqdtLkF2KexO40H1YTX8z2lSgBBOAxLsvaklV8k4cBFK9snQXE9/DDaFt6Rr7iVZMldczhC0JNgTz+SHXT6CBHuX3e9SdB1Ua44oncaTWz7OBGLbCiK45wIDAQAB")!
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(spki.dropFirst(22) as CFData, [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPublic] as CFDictionary, &error) else { throw NeteaseAccountError.requestEncoding }
        let block = Data(repeating: 0, count: 112) + Data(secret.reversed())
        guard let encrypted = SecKeyCreateEncryptedData(key, .rsaEncryptionRaw, block as CFData, &error) as Data? else { throw NeteaseAccountError.requestEncoding }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let encoded = params.addingPercentEncoding(withAllowedCharacters: allowed)!
        let rsa = encrypted.map { String(format: "%02x", $0) }.joined()
        var request = URLRequest(url: URL(string: "https://music.163.com/weapi/" + path.dropFirst(5))!)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.httpShouldHandleCookies = false
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("https://music.163.com", forHTTPHeaderField: "Origin")
        request.setValue("https://music.163.com", forHTTPHeaderField: "Referer")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        // Web client profile adapted from NeoDizzy NeteaseClient.makeWebRequest (GPL-3.0).
        let timestamp = Int64(Date().timeIntervalSince1970 * 1000)
        let cookies = ["MUSIC_U": credential.musicU, "__csrf": credential.csrf ?? "",
                       "os": "ios", "appver": "9.0.90", "osver": "16.2", "channel": "distribution",
                       "deviceId": deviceID, "__remember_me": "true", "ntes_kaola_ad": "1",
                       "_ntes_nuid": deviceID, "_ntes_nnid": "\(deviceID),\(timestamp)", "WEVNSM": "1.0.0",
                       "WNMCID": "\(deviceID.prefix(6)).\(timestamp).01.0", "NMTID": UUID().uuidString.replacingOccurrences(of: "-", with: "")]
        request.setValue(cookies.keys.sorted().map {
            "\($0)=\(cookies[$0]!.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")"
        }.joined(separator: "; "), forHTTPHeaderField: "Cookie")
        request.httpBody = Data("params=\(encoded)&encSecKey=\(rsa)".utf8)
        return request
    }
    @concurrent func requestWeb(path: String, fields: [String: any Sendable], credential: NeteaseCredential) async throws -> Data {
        try Task.checkCancellation()
        let (data, response) = try await session.data(for: makeWebRequest(path: path, fields: fields, credential: credential))
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw NeteaseAccountError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw NeteaseAccountError.http(http.statusCode) }
        struct Status: Decodable { let code: Int; let message: String?; let msg: String? }
        let status = try JSONDecoder().decode(Status.self, from: data)
        guard status.code == 200 else { throw NeteaseWebResponseError(code: status.code, message: status.message ?? status.msg) }
        return data
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

/// A web operation rejection is kept separate from account-profile authentication.
struct NeteaseWebResponseError: LocalizedError, Equatable, Sendable {
    let code: Int
    let message: String?
    var errorDescription: String? {
        if let message, !message.isEmpty { return "\(message)（\(code)）" }
        return "网易云音乐请求失败（\(code)），请稍后重试。"
    }
}
