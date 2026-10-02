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
    /// The whole poll failed (bad address, unreadable response, server error).
    case pollFailed(String)
    /// Connected, but the first reports aren't computed yet.
    case waiting
    /// Recording works but nothing was recorded in this range.
    case empty
    case data

    public static func resolve(connection: ConnectionState, usageAvailable: Bool,
                               queueError: String?, report: UsageReport?) -> UsageState {
        // Recorded history is always shown; a current problem is surfaced
        // separately (see `issue`), so one failed poll never blanks the section.
        if let report, report.totals.requests > 0 { return .data }
        return issue(connection: connection, usageAvailable: usageAvailable, queueError: queueError)
            ?? (report == nil ? .waiting : .empty)
    }

    /// What currently prevents recording usage, if anything.
    public static func issue(connection: ConnectionState, usageAvailable: Bool, queueError: String?) -> UsageState? {
        switch connection {
        case .needsKey: return .needsKey
        case .keyRejected: return .keyRejected
        case .proxyDown: return .proxyUnreachable
        case .failed(let reason): return .pollFailed(reason)
        case .connecting, .connected: break
        }
        if !usageAvailable { return .queueUnavailable }
        if let queueError { return .queueError(queueError) }
        return nil
    }

    /// User-facing explanation; nil when there is data to show.
    public var message: String? {
        switch self {
        case .needsKey: "Add your management key in Settings to start recording usage."
        case .keyRejected: "The proxy rejected the management key (401), so usage can't be read."
        case .proxyUnreachable: "The proxy isn't answering, so no usage is being recorded."
        case .queueUnavailable: "This proxy has no usage queue (404). Update CLIProxyAPI or turn on usage statistics."
        case .queueError(let reason): "Couldn't read the usage queue: \(reason)."
        case .pollFailed(let reason): "Can't read the proxy (\(reason)), so usage isn't being recorded."
        case .waiting: "Reading the usage queue…"
        case .empty: "No requests in this range yet. They appear after requests go through the proxy."
        case .data: nil
        }
    }
}
