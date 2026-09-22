import Foundation
import Network
import Combine

/// Thin NWPathMonitor wrapper that logs wifi / cellular / other path changes.
@MainActor
final class NetworkPathMonitor: ObservableObject {
    @Published private(set) var pathDescription: String = "path: unknown"

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "WebRTCReconnectMock.NWPathMonitor")
    private weak var log: StatusLog?
    private var started = false

    init(log: StatusLog) {
        self.log = log
    }

    func start() {
        guard !started else { return }
        started = true
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                self?.handle(path)
            }
        }
        monitor.start(queue: queue)
        log?.append("NWPathMonitor started")
    }

    func stop() {
        guard started else { return }
        monitor.cancel()
        started = false
        log?.append("NWPathMonitor stopped")
    }

    private func handle(_ path: NWPath) {
        let status: String
        switch path.status {
        case .satisfied: status = "satisfied"
        case .unsatisfied: status = "unsatisfied"
        case .requiresConnection: status = "requiresConnection"
        @unknown default: status = "unknown"
        }

        var interfaces: [String] = []
        if path.usesInterfaceType(.wifi) { interfaces.append("wifi") }
        if path.usesInterfaceType(.cellular) { interfaces.append("cellular") }
        if path.usesInterfaceType(.wiredEthernet) { interfaces.append("wiredEthernet") }
        if path.usesInterfaceType(.loopback) { interfaces.append("loopback") }
        if path.usesInterfaceType(.other) { interfaces.append("other") }
        if interfaces.isEmpty { interfaces.append("none") }

        let expensive = path.isExpensive ? "expensive" : "cheap"
        let constrained = path.isConstrained ? "constrained" : "unconstrained"
        let desc = "path \(status) via \(interfaces.joined(separator: "+")) (\(expensive), \(constrained))"
        pathDescription = desc
        log?.append(desc)
    }
}
