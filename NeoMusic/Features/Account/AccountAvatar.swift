import SwiftUI
import ImageIO

struct AccountAvatar: View {
    let account: NeteaseAccount
    let size: CGFloat
    @Environment(\.displayScale) private var displayScale
    @State private var decodedImage: UIImage?
    @State private var decodedTaskKey: AvatarTaskKey?

    private struct AvatarTaskKey: Equatable {
        let data: Data?
        let pixels: Int
    }

    private var pixels: Int { max(1, Int(ceil(size * displayScale))) }

    private var taskKey: AvatarTaskKey {
        AvatarTaskKey(data: account.avatarData, pixels: pixels)
    }

    private var displayedImage: UIImage? {
        if let data = account.avatarData,
           let cached = AccountAvatarImages.cachedImage(data, pixels: pixels) {
            return cached
        }
        return decodedTaskKey == taskKey ? decodedImage : nil
    }

    var body: some View {
        Group {
            if let image = displayedImage {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Circle()
                    .fill(LinearGradient(colors: [Color(red: 0.67, green: 0.77, blue: 0.90),
                                                 Color(red: 0.47, green: 0.51, blue: 0.73)],
                                         startPoint: .top, endPoint: .bottom))
                    .overlay {
                        Text("NM")
                            .font(.system(size: size * 0.447, weight: .semibold))
                            .foregroundStyle(.white)
                    }
            }
        }
        .frame(width: size, height: size)
        .clipShape(.circle)
        .accessibilityHidden(true)
        .task(id: taskKey) {
            let key = taskKey
            guard let data = key.data else {
                decodedImage = nil
                decodedTaskKey = key
                return
            }
            if let cached = AccountAvatarImages.cachedImage(data, pixels: key.pixels) {
                decodedImage = cached
                decodedTaskKey = key
                return
            }
            let image = await AccountAvatarImages.loadImage(data, pixels: key.pixels)
            guard !Task.isCancelled else { return }
            decodedImage = image
            decodedTaskKey = key
        }
    }
}

@MainActor private enum AccountAvatarImages {
    private static let cache: NSCache<Key, UIImage> = {
        let cache = NSCache<Key, UIImage>()
        cache.totalCostLimit = 2 * 1_024 * 1_024
        return cache
    }()

    static func cachedImage(_ data: Data, pixels: Int) -> UIImage? {
        cache.object(forKey: Key(data: data, pixels: pixels))
    }

    static func loadImage(_ data: Data, pixels: Int) async -> UIImage? {
        let key = Key(data: data, pixels: pixels)
        if let image = cache.object(forKey: key) { return image }
        let decoded = await Task.detached(priority: .utility) {
            decodeThumbnail(data, pixels: pixels)
        }.value
        guard let decoded else { return nil }
        let image = UIImage(cgImage: decoded.cgImage)
        cache.setObject(image, forKey: key, cost: decoded.cost)
        return image
    }

    private nonisolated static func decodeThumbnail(_ data: Data, pixels: Int) -> (cgImage: CGImage, cost: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: max(1, pixels)
              ] as CFDictionary) else { return nil }
        return (thumbnail, thumbnail.bytesPerRow * thumbnail.height)
    }

    private final class Key: NSObject {
        let data: Data
        let pixels: Int
        init(data: Data, pixels: Int) { self.data = data; self.pixels = pixels }
        override var hash: Int { data.hashValue ^ pixels.hashValue }
        override func isEqual(_ object: Any?) -> Bool {
            guard let other = object as? Key else { return false }
            return pixels == other.pixels && data == other.data
        }
    }
}

struct AccountButton: View {
    @Environment(NeteaseAccount.self) private var account
    @State private var isPresented = false

    var body: some View {
        Button { isPresented = true } label: {
            AccountAvatar(account: account, size: 36)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("账户")
        .accessibilityIdentifier("account.open")
        .sheet(isPresented: $isPresented) { AccountPage(account: account) }
    }
}

extension View {
    /// 作为标签栏根页面时，右上角使用和其他主标签相同的账户按钮。
    func libraryRootAccountButton() -> some View { modifier(LibraryRootAccountButton()) }
}

private struct LibraryRootAccountButton: ViewModifier {
    @Environment(\.libraryNavigationChrome) private var chrome
    func body(content: Content) -> some View {
        content.toolbar { if chrome?.isRoot == true { AccountToolbar() } }
    }
}

struct AccountToolbar: ToolbarContent {
    var body: some ToolbarContent {
        ToolbarSpacer(.fixed, placement: .topBarTrailing)
        ToolbarItem(placement: .topBarTrailing) { AccountButton() }
    }
}
