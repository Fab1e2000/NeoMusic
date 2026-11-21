import SwiftUI
import UIKit

struct CollectionPagePalette: Equatable {
    let background: UIColor
    let isDark: Bool

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
    var swiped: UIColor {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        guard background.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return background }
        let lift: CGFloat = isDark ? 0.06 : 0
        return UIColor(red: red * 0.94 + lift, green: green * 0.94 + lift, blue: blue * 0.94 + lift, alpha: alpha)
    }
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
