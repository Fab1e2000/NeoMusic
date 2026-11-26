import SwiftUI

public struct FrontAMViewEventAction: Sendable {
    private let handler: @MainActor @Sendable (String, String) -> Void

    public init(_ handler: @escaping @MainActor @Sendable (String, String) -> Void = { _, _ in }) {
        self.handler = handler
    }

    @MainActor public func callAsFunction(_ event: String, _ subject: String) {
        handler(event, subject)
    }
}

extension EnvironmentValues {
    @Entry public var frontAMViewEvent = FrontAMViewEventAction()
}
