import Foundation

#if os(iOS)
    import UIKit
#endif

/// A finite UIKit execution grant for the main app's shared outbox dispatcher.
@MainActor
final class OutboxBackgroundExecution {
    typealias Start = @MainActor (
        _ expire: @escaping @MainActor () -> Void
    ) -> OutboxBackgroundExecution?

    private var end: (() -> Void)?

    init(end: @escaping () -> Void) {
        self.end = end
    }

    func finish() {
        let action = end
        end = nil
        action?()
    }

    static func start(expire: @escaping @MainActor () -> Void) -> OutboxBackgroundExecution? {
        #if os(iOS)
            let task = UIApplication.shared.beginBackgroundTask(withName: "Outbox send") {
                MainActor.assumeIsolated { expire() }
            }
            guard task != .invalid else { return nil }
            return OutboxBackgroundExecution { UIApplication.shared.endBackgroundTask(task) }
        #else
            return nil
        #endif
    }
}
