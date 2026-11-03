import Foundation

/// Public avatar responses use a dedicated system cache without authentication cookies.
struct NeteaseAvatarClient: Sendable {
    private let session: URLSession

    init(session: URLSession? = nil) {
        self.session = session ?? URLSession(configuration: Self.sessionConfiguration())
    }

    static func sessionConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.default
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = URLCache(memoryCapacity: 2 * 1024 * 1024, diskCapacity: 20 * 1024 * 1024,
                                          directory: URL.cachesDirectory.appending(path: "NeteaseAvatar"))
        return configuration
    }

    func clearCache() {
        session.configuration.urlCache?.removeAllCachedResponses()
    }

    func cachedData(for url: URL) async -> Data? {
        guard !Task.isCancelled,
              let cached = session.configuration.urlCache?.cachedResponse(for: URLRequest(url: url)),
              let response = cached.response as? HTTPURLResponse,
              (200..<300).contains(response.statusCode), !cached.data.isEmpty else { return nil }
        return cached.data
    }

    func data(for url: URL) async throws -> Data {
        guard url.scheme == "https", url.host != nil else { throw URLError(.badURL) }
        try Task.checkCancellation()
        var request = URLRequest(url: url, cachePolicy: .useProtocolCachePolicy)
        request.httpShouldHandleCookies = false
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse,
              (200..<300).contains(response.statusCode), !data.isEmpty else {
            throw URLError(.badServerResponse)
        }
        return data
    }
}
