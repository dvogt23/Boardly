import Foundation
import Network

/// Whether the device currently has a usable path to the network.
///
/// Reachability is a hint, never a gate: a mutation is still attempted when this says
/// online (the request may fail anyway) and queued when it says offline. The sync engine
/// only uses it to decide *when to try*, so a wrong answer costs a retry, not data.
public protocol ConnectivityMonitoring: Sendable {
    var isOnline: Bool { get async }
    /// Emits on every change, starting with the current value.
    var changes: AsyncStream<Bool> { get async }
}

public actor NetworkMonitor: ConnectivityMonitoring {
    private let monitor = NWPathMonitor()
    private var current = true
    private var continuations: [UUID: AsyncStream<Bool>.Continuation] = [:]
    private var started = false

    public init() {}

    public var isOnline: Bool {
        get async {
            start()
            return current
        }
    }

    public var changes: AsyncStream<Bool> {
        get async {
            start()
            let id = UUID()
            let value = current
            return AsyncStream { continuation in
                continuations[id] = continuation
                continuation.yield(value)
                continuation.onTermination = { [weak self] _ in
                    Task { await self?.removeContinuation(id) }
                }
            }
        }
    }

    private func start() {
        guard !started else { return }
        started = true
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { await self?.update(online) }
        }
        monitor.start(queue: DispatchQueue(label: "dev.boardly.network-monitor"))
    }

    private func update(_ online: Bool) {
        guard online != current else { return }
        current = online
        BoardlyLog.tag(.sync).icon(online ? "🛜" : "✈️")
            .info("Connectivity changed", metadata: ["online": online])
        for continuation in continuations.values { continuation.yield(online) }
    }

    private func removeContinuation(_ id: UUID) {
        continuations[id] = nil
    }
}
