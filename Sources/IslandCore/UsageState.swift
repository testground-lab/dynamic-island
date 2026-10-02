import Foundation

/// Why the Usage section shows what it shows. The section is always rendered;
/// when there's nothing to chart, this says why.
public enum UsageState: Equatable, Sendable {
    case needsKey
    case keyRejected
    case proxyUnreachable
    /// The proxy answered 404 for the usage queue (endpoint missing or disabled).
    case queueUnavailable
    /// Reading the queue failed for another reason.
    case queueError(String)
    /// Connected, but the first reports aren't computed yet.
    case waiting
    /// Recording works but nothing was recorded in this range.
    case empty
    case data

    public static func resolve(connection: ConnectionState, usageAvailable: Bool,
                               queueError: String?, report: UsageReport?) -> UsageState {
        switch connection {
        case .needsKey: return .needsKey
        case .keyRejected: return .keyRejected
        case .proxyDown: return report.map { $0.totals.requests > 0 ? .data : .proxyUnreachable } ?? .proxyUnreachable
        case .connecting, .connected, .failed: break
        }
        if !usageAvailable { return .queueUnavailable }
        if let queueError { return .queueError(queueError) }
        guard let report else { return .waiting }
        return report.totals.requests > 0 ? .data : .empty
    }

    /// User-facing explanation; nil when there is data to show.
    public var message: String? {
        switch self {
        case .needsKey: "Add your management key in Settings to start recording usage."
        case .keyRejected: "The proxy rejected the management key (401), so usage can't be read."
        case .proxyUnreachable: "The proxy isn't answering, so no usage is being recorded."
        case .queueUnavailable: "Usage queue unavailable: the proxy returned 404 for /v0/management/usage-queue."
        case .queueError(let reason): "Usage queue unavailable: \(reason)."
        case .waiting: "Reading the usage queue…"
        case .empty: "No usage recorded yet. Records appear after the next request through the proxy."
        case .data: nil
        }
    }
}
