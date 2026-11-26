import FrontAMPlayer
import LNPopupUI
import SwiftUI

public struct FrontAMPopupArtworkTransition: ViewModifier {
    @Environment(\.playerArtworkTransitionTargetVisible) private var targetVisible

    public init() {}

    public func body(content: Content) -> some View {
        content.popupTransitionTarget(isEnabled: targetVisible)
    }
}
