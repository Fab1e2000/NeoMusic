import SwiftUI
import UIKit

/// 专辑／歌单详情页配色。Apple Music 实测：前景层对不透明底色做逐通道等量增减
/// （等效 plusLighter／plusDarker），这里预先算成实色，避免逐行离屏混合。
struct CollectionPagePalette: Equatable {
    let background: UIColor
    let isDark: Bool

    /// 待原图标定；标定前取 0.12，使白底上与原 0.18 黑的观感接近。
    static let separatorShift: CGFloat = 0.12

    init(background: UIColor, isDark: Bool) {
        let traits = UITraitCollection(userInterfaceStyle: isDark ? .dark : .light)
        self.background = background.resolvedColor(with: traits)
        self.isDark = isDark
    }

    static func page(_ backdrop: AlbumArtworkBackdrop?, fallback: UIColor = .systemBackground, scheme: ColorScheme) -> Self {
        let effectiveScheme = backdrop?.colorScheme ?? scheme
        return Self(background: backdrop?.uiColor ?? fallback, isDark: effectiveScheme == .dark)
    }

    /// 深色页向白偏移，浅色页向黑偏移；三通道同量，超出范围截断。
    func shifted(_ amount: CGFloat) -> UIColor {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        guard background.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
            return isDark ? .secondaryLabel : .secondaryLabel
        }
        let offset: CGFloat = isDark ? amount : -amount
        return UIColor(
            red: min(1, max(0, red + offset)),
            green: min(1, max(0, green + offset)),
            blue: min(1, max(0, blue + offset)),
            alpha: 1
        )
    }

    var secondary: UIColor { shifted(0.5) }
    var controlFill: Color { Color(uiColor: shifted(0.075)) }
    var separator: UIColor { shifted(Self.separatorShift) }
    var highlight: UIColor { shifted(0.075) }
    var playForeground: Color { Color(uiColor: background) }
    var secondaryColor: Color { Color(uiColor: secondary) }
}

private struct CollectionPagePaletteKey: EnvironmentKey {
    static let defaultValue: CollectionPagePalette? = nil
}

extension EnvironmentValues {
    var collectionPagePalette: CollectionPagePalette? {
        get { self[CollectionPagePaletteKey.self] }
        set { self[CollectionPagePaletteKey.self] = newValue }
    }
}

struct CollectionCircleButtonStyle: ButtonStyle {
    @Environment(\.collectionPagePalette) private var palette

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(.primary)
            .frame(width: 48, height: 48)
            .background(palette?.controlFill ?? Color.primary.opacity(0.08), in: .circle)
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}
