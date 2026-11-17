import Foundation
import Network

/// Reachability as "a TCP connect to the share's port succeeds within the timeout". A refused connection fails
/// fast; a silent host (dropped packets, wrong network) fails at the timeout.
public struct TCPReachabilityProber: ReachabilityProber {
    public init() {}

    public func isReachable(host: String, port: Int, timeout: Duration) async -> Bool {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: max(0, port))), port > 0 else { return false }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        let queue = DispatchQueue(label: "dev.noix.MacCommander.TCPReachabilityProber")
        let probe = Probe(connection: connection)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                probe.setContinuation(continuation)
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready: probe.finish(true)
                    // `.waiting` means the connect failed for now (refused, no route); NWConnection would retry,
                    // but a probe wants the current answer.
                    case .failed, .waiting, .cancelled: probe.finish(false)
                    default: break
                    }
                }
                connection.start(queue: queue)
                queue.asyncAfter(deadline: .now() + timeout.timeInterval) { probe.finish(false) }
            }
        } onCancel: {
            probe.finish(false)
        }
    }
}

/// Resumes the probe's continuation exactly once and always cancels the connection.
private final class Probe: @unchecked Sendable {
    private let lock = NSLock()
    private let connection: NWConnection
    private var continuation: CheckedContinuation<Bool, Never>?
    private var result: Bool?

    init(connection: NWConnection) {
        self.connection = connection
    }

    func setContinuation(_ continuation: CheckedContinuation<Bool, Never>) {
        let early: Bool? = lock.withLock {
            if let result { return result }
            self.continuation = continuation
            return nil
        }
        if let early { continuation.resume(returning: early) }
    }

    func finish(_ reachable: Bool) {
        let (first, continuation): (Bool, CheckedContinuation<Bool, Never>?) = lock.withLock {
            guard result == nil else { return (false, nil) }
            result = reachable
            defer { self.continuation = nil }
            return (true, self.continuation)
        }
        guard first else { return }
        connection.cancel()
        continuation?.resume(returning: reachable)
    }
}

extension Duration {
    /// Seconds as a `TimeInterval`.
    var timeInterval: TimeInterval {
        let (seconds, attoseconds) = components
        return TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
    }
}
