import Foundation

public enum BaseURLValidator {
    public static let defaultBaseURL = "http://127.0.0.1:8317"
    public static func validate(_ string: String) -> URL? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var c = URLComponents(string: trimmed), let scheme = c.scheme?.lowercased(),
              let host = c.host?.lowercased(), !host.isEmpty,
              c.user == nil, c.password == nil, c.query == nil, c.fragment == nil,
              c.path.isEmpty || c.path == "/",
              c.port.map({ (1...65535).contains($0) }) ?? true,
              scheme == "https" || (scheme == "http" && ["127.0.0.1", "localhost", "::1", "[::1]"].contains(host)) else { return nil }
        c.scheme = scheme; c.path = ""
        return c.url
    }
}
