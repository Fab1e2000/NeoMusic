import SwiftUI

/// Only the source palette entries actually consumed by the player are carried over.
enum DizzyPalette {
    static let artworkPlaceholder = Color(UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 38/255, green: 38/255, blue: 38/255, alpha: 1) : .white })
    static let artworkPlaceholderSymbol = Color(UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 145/255, green: 154/255, blue: 161/255, alpha: 1)
        : UIColor(red: 106/255, green: 115/255, blue: 123/255, alpha: 1) })
}
