import Foundation

public enum BaseURLValidator {
    public static let defaultBaseURL = "http://127.0.0.1:8317"
    // URLComponents.host retains IPv6 brackets on some Foundation versions.
    private static func normalizedHost(_ host: String) -> String {
        host.hasPrefix("[") && host.hasSuffix("]") ? String(host.dropFirst().dropLast()) : host
    }

    public static func validate(_ string: String) -> URL? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var c = URLComponents(string: trimmed), let scheme = c.scheme?.lowercased(),
            let rawHost = c.host?.lowercased(), !rawHost.isEmpty,
            c.user == nil, c.password == nil, c.query == nil, c.fragment == nil,
            c.path.isEmpty || c.path == "/",
            c.port.map({ (1...65535).contains($0) }) ?? true,
            scheme == "https"
                || (scheme == "http"
                    && ["127.0.0.1", "localhost", "::1"].contains(normalizedHost(rawHost)))
        else { return nil }
        c.scheme = scheme
        c.path = ""
        return c.url
    }
}
