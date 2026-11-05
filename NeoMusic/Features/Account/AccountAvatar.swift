import SwiftUI
import ImageIO

struct AccountAvatar: View {
    let account: NeteaseAccount
    let size: CGFloat
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Group {
            if let data = account.avatarData,
               let image = AccountAvatarImages.image(data, pixels: Int(ceil(size * displayScale))) {
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
    }
}

@MainActor private enum AccountAvatarImages {
    private static let cache: NSCache<Key, UIImage> = {
        let cache = NSCache<Key, UIImage>()
        cache.totalCostLimit = 2 * 1_024 * 1_024
        return cache
    }()

    static func image(_ data: Data, pixels: Int) -> UIImage? {
        let key = Key(data: data, pixels: pixels)
        if let image = cache.object(forKey: key) { return image }
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: max(1, pixels)
              ] as CFDictionary) else { return nil }
        let image = UIImage(cgImage: thumbnail)
        cache.setObject(image, forKey: key, cost: thumbnail.bytesPerRow * thumbnail.height)
        return image
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
        }
        .buttonStyle(.plain)
        .accessibilityLabel("账户")
        .accessibilityIdentifier("account.open")
        .sheet(isPresented: $isPresented) { AccountPage(account: account) }
    }
}

struct AccountToolbar: ToolbarContent {
    var body: some ToolbarContent {
        ToolbarSpacer(.fixed, placement: .topBarTrailing)
        ToolbarItem(placement: .topBarTrailing) { AccountButton() }
    }
}
