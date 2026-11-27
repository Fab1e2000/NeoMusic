import UIKit

@MainActor
public enum LibraryHaptics {
    public enum Feedback: Sendable { case impact, lightImpact, mediumImpact, success, error }

    /// Each output coordinates its own pulses, including when a task supplies a recording output.
    @MainActor public final class Output {
        fileprivate let timing = LibraryFeedbackTiming()
        fileprivate let emit: @MainActor (Feedback) -> Void

        public init(_ emit: @escaping @MainActor (Feedback) -> Void) {
            self.emit = emit
        }
    }

    @TaskLocal public static var output: Output?
    private static let device = Output(emitOnDevice)
    private static var generators: Generators?

    public static func prepareImpact() { currentGenerators()?.soft.prepare() }
    public static func prepareSuccess() { currentGenerators()?.notification.prepare() }
    nonisolated public static func impact() { onMain { positive(.impact) } }
    nonisolated public static func lightImpact() { onMain { positive(.lightImpact) } }
    nonisolated public static func mediumImpact() { onMain { positive(.mediumImpact) } }
    nonisolated public static func success() { onMain { positive(.success) } }

    private nonisolated static func onMain(_ action: @escaping @MainActor @Sendable () -> Void) {
        if Thread.isMainThread { MainActor.assumeIsolated(action) }
        else { Task { @MainActor in action() } }
    }

    public static func error() {
        let target = output ?? device
        target.timing.error { target.emit(.error) }
    }

    private static func positive(_ feedback: Feedback) {
        let target = output ?? device
        target.timing.recordPositive()
        target.emit(feedback)
    }

    private static func emitOnDevice(_ feedback: Feedback) {
        guard let generators = currentGenerators() else { return }
        switch feedback {
        case .impact: generators.soft.impactOccurred(intensity: 0.6)
        case .lightImpact: generators.light.impactOccurred()
        case .mediumImpact: generators.medium.impactOccurred()
        case .success: generators.notification.notificationOccurred(.success)
        case .error: generators.notification.notificationOccurred(.error)
        }
    }

    private static func currentGenerators() -> Generators? {
        guard let scene = UIApplication.shared.connectedScenes.lazy.compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }),
              let window = feedbackWindow(keyWindow: scene.keyWindow, windows: scene.windows) else { return nil }
        if generators?.window !== window { generators = Generators(window) }
        return generators
    }

    static func feedbackWindow(keyWindow: UIWindow?, windows: @autoclosure () -> [UIWindow]) -> UIWindow? {
        if let keyWindow { return keyWindow }
        let candidates = windows()
        return candidates.first(where: \.isKeyWindow) ?? candidates.first
    }

    @MainActor private final class Generators {
        weak var window: UIWindow?
        let soft: UIImpactFeedbackGenerator
        let light: UIImpactFeedbackGenerator
        let medium: UIImpactFeedbackGenerator
        let notification: UINotificationFeedbackGenerator

        init(_ window: UIWindow) {
            self.window = window
            soft = .init(style: .soft, view: window)
            light = .init(style: .light, view: window)
            medium = .init(style: .medium, view: window)
            notification = .init(view: window)
        }
    }
}

/// Only the physical error pulse waits. Error presentation and rollback stay synchronous.
@MainActor
final class LibraryFeedbackTiming {
    static let separation = Duration.milliseconds(150)
    private let now: () -> ContinuousClock.Instant
    private let sleep: (ContinuousClock.Instant) async -> Void
    private var hasPendingError = false
    private var lastPositive: ContinuousClock.Instant?

    init(now: @escaping () -> ContinuousClock.Instant = { .now },
         sleep: @escaping (ContinuousClock.Instant) async -> Void = { try? await Task.sleep(until: $0, clock: .continuous) }) {
        self.now = now
        self.sleep = sleep
    }

    func recordPositive() { lastPositive = now() }

    private var deadline: ContinuousClock.Instant? {
        guard let deadline = lastPositive?.advanced(by: Self.separation), deadline > now() else { return nil }
        return deadline
    }

    func error(_ emit: @escaping @MainActor () -> Void) {
        guard !hasPendingError else { return }
        guard let deadline else { emit(); return }
        hasPendingError = true
        Task {
            await sleep(deadline)
            while let next = self.deadline { await sleep(next) }
            hasPendingError = false
            emit()
        }
    }
}
