import SwiftUI
import UIKit

/// 歌词行高：iOS 用 UIFont.lineHeight，macOS 用 NSLayoutManager 的默认行高，两者都对应系统粗体。
enum LyricsFontMetrics {
    static func boldLineHeight(size: CGFloat) -> CGFloat {
        UIFont.systemFont(ofSize: size, weight: .bold).lineHeight
    }
}
