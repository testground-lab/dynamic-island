import Foundation

public enum ManagementError: Error, Equatable, Sendable {
    case proxyDown(String), unauthorized, http(Int), decoding(String), invalidBaseURL
}

public protocol HTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

extension URLSession: HTTPTransport {
    public static let islandEphemeral: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.urlCache = nil; c.httpCookieStorage = nil; c.httpShouldSetCookies = false
        c.timeoutIntervalForRequest = 8; c.timeoutIntervalForResource = 20
        return URLSession(configuration: c)
    }()
    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response): (Data, URLResponse) = try await data(for: request, delegate: nil)
        guard let response = response as? HTTPURLResponse else { throw ManagementError.decoding("Invalid HTTP response") }
        return (data, response)
    }
}

public struct UsageDrainResult: Sendable {
    public let records: [UsageRecord]
    public let available: Bool
}

public struct ManagementClient: Sendable {
    private let baseURL: URL
    private let key: String
    private let transport: any HTTPTransport
    public init(baseURL: URL, key: String, session: URLSession = .islandEphemeral) {
        self.baseURL = baseURL; self.key = key; self.transport = session
    }
    public init(baseURL: URL, key: String, transport: any HTTPTransport) {
        self.baseURL = baseURL; self.key = key; self.transport = transport
    }
    public func authFiles() async throws -> AuthFilesResponse {
        try decode(AuthFilesResponse.self, data: await send(path: "auth-files"))
    }
    public func apiCall(_ request: APICallRequest) async throws -> APICallResponse {
        let body: Data
        do { body = try JSONEncoder().encode(request) } catch { throw ManagementError.decoding("Invalid API call request") }
        return try decode(APICallResponse.self, data: await send(path: "api-call", body: body))
    }
    public func drainUsageQueue(batchSize: Int = 500, maxBatches: Int = 10) async throws -> [UsageRecord] {
        try await drainUsageQueueResult(batchSize: batchSize, maxBatches: maxBatches).records
    }
    /// Carries endpoint availability separately from a genuinely empty queue.
    public func drainUsageQueueResult(batchSize: Int = 500, maxBatches: Int = 10) async throws -> UsageDrainResult {
        let size = max(1, batchSize)
        var records: [UsageRecord] = []
        for _ in 0..<max(0, maxBatches) {
            let data: Data
            do { data = try await send(path: "usage-queue", query: [URLQueryItem(name: "count", value: String(size))]) }
            catch ManagementError.http(404) { return UsageDrainResult(records: records, available: false) }
            let batch = try decode(UsageQueueBatch.self, data: data)
            records.append(contentsOf: batch.records)
            if batch.rawCount < size { break }
        }
        return UsageDrainResult(records: records, available: true)
    }
    private func decode<T: Decodable>(_ type: T.Type, data: Data) throws -> T {
        do { return try JSONDecoder().decode(type, from: data) }
        catch { throw ManagementError.decoding("Invalid management response") }
    }
    private func send(path: String, query: [URLQueryItem] = [], body: Data? = nil) async throws -> Data {
        guard let valid = BaseURLValidator.validate(baseURL.absoluteString),
              var c = URLComponents(url: valid, resolvingAgainstBaseURL: false) else { throw ManagementError.invalidBaseURL }
        c.path = "/v0/management/" + path; c.queryItems = query.isEmpty ? nil : query
        guard let url = c.url else { throw ManagementError.invalidBaseURL }
        var request = URLRequest(url: url)
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        if let body { request.httpMethod = "POST"; request.httpBody = body; request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let data: Data; let response: HTTPURLResponse
        do { (data, response) = try await transport.data(for: request) }
        catch is CancellationError { throw CancellationError() }
        catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            switch error.code {
            case .cannotConnectToHost, .timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotFindHost:
                // Use our own message; localized errors may contain URLs or reflected credentials.
                throw ManagementError.proxyDown("Gateway unavailable (\(error.code.rawValue))")
            default: throw ManagementError.proxyDown("Network request failed")
            }
        }
        catch { throw ManagementError.proxyDown("Network request failed") }
        if response.statusCode == 401 || response.statusCode == 403 { throw ManagementError.unauthorized }
        guard (200..<300).contains(response.statusCode) else { throw ManagementError.http(response.statusCode) }
        return data
    }
}
