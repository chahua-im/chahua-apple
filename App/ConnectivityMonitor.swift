import Combine
import Network

nonisolated struct ConnectivitySnapshot: Equatable, Sendable {
    enum Status: Equatable, Sendable { case unknown, satisfied, unsatisfied }

    var status: Status = .unknown
    var isExpensive = false
    var isConstrained = false

    /// The path is a hint. Unknown permits a bounded attempt; satisfied does
    /// not prove that authentication, HTTP or the socket can succeed.
    var canAttempt: Bool { status != .unsatisfied }
    var allowsAutomaticFullMedia: Bool { canAttempt && !isExpensive && !isConstrained }
}

@MainActor
final class ConnectivityMonitor: ObservableObject {
    @Published private(set) var snapshot = ConnectivitySnapshot()
    private let monitor: NWPathMonitor?

    init(monitorNetwork: Bool = true) {
        let monitor = monitorNetwork ? NWPathMonitor() : nil
        self.monitor = monitor
        monitor?.pathUpdateHandler = { [weak self] path in
            let status: ConnectivitySnapshot.Status = switch path.status {
            case .satisfied: .satisfied
            case .unsatisfied: .unsatisfied
            case .requiresConnection: .unknown
            @unknown default: .unknown
            }
            let snapshot = ConnectivitySnapshot(
                status: status,
                isExpensive: path.isExpensive, isConstrained: path.isConstrained)
            DispatchQueue.main.async { [weak self = self] in self?.update(snapshot) }
        }
        monitor?.start(queue: DispatchQueue(label: "app.chahua.chat.connectivity"))
    }

    deinit { monitor?.cancel() }

    func update(_ snapshot: ConnectivitySnapshot) {
        if self.snapshot != snapshot { self.snapshot = snapshot }
    }
}
