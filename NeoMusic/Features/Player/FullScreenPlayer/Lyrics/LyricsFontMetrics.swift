import SwiftUI
import UIKit

enum LyricsFontMetrics {
    static func boldLineHeight(size: CGFloat) -> CGFloat {
        UIFont.systemFont(ofSize: size, weight: .bold).lineHeight
    }
}
