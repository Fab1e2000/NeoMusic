import SwiftUI

extension ButtonStyle {
    /// Keep the control's normal activation and cancellation behavior while warming its generator.
    public func preparingFeedback(_ prepare: @escaping @MainActor () -> Void) -> some ButtonStyle {
        PreparingFeedbackButtonStyle(base: self, prepare: prepare)
    }
}

private struct PreparingFeedbackButtonStyle<Base: ButtonStyle>: ButtonStyle {
    let base: Base
    let prepare: @MainActor () -> Void

    func makeBody(configuration: Configuration) -> some View {
        base.makeBody(configuration: configuration)
            .onChange(of: configuration.isPressed) { _, pressed in
                if pressed { prepare() }
            }
    }
}

extension PlainButtonStyle {
    public func preparingFeedback(_ prepare: @escaping @MainActor () -> Void) -> some PrimitiveButtonStyle {
        PreparingPlainButtonStyle(prepare: prepare)
    }
}

private struct PreparingPlainButtonStyle: PrimitiveButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    let prepare: @MainActor () -> Void

    func makeBody(configuration: Configuration) -> some View {
        // PlainButtonStyle owns activation and cancellation. Its configuration exposes no isPressed.
        PlainButtonStyle().makeBody(configuration: configuration)
            .simultaneousGesture(LongPressGesture(minimumDuration: 0).onEnded { _ in prepare() },
                                 isEnabled: isEnabled)
    }
}
