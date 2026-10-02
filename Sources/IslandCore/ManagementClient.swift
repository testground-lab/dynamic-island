import Foundation

public enum ManagementError: Error, Equatable, Sendable {
    case proxyDown(String)
    case unauthorized
    case http(Int)
    case decoding(String)
    case invalidBaseURL
    case responseTooLarge
}

public protocol HTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

private final class RefuseRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

extension URLSession: HTTPTransport {
    static let islandResponseLimit = 8 * 1024 * 1024

    public static let islandEphemeral: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 20
        return URLSession(configuration: configuration)
    }()

    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (bytes, response) = try await bytes(for: request, delegate: RefuseRedirects())
        defer { bytes.task.cancel() }
        guard let response = response as? HTTPURLResponse else {
            throw ManagementError.decoding("Invalid HTTP response")
        }
        guard response.expectedContentLength <= Int64(Self.islandResponseLimit) else {
            throw ManagementError.responseTooLarge
        }
        let data = try await Self.boundedData(from: bytes)
        return (data, response)
    }

    /// Incremental consumption bounds allocation even without a reliable Content-Length.
    static func boundedData<Bytes: AsyncSequence>(
        from bytes: Bytes,
        limit: Int = islandResponseLimit
    ) async throws -> Data where Bytes.Element == UInt8 {
        var data = Data()
        for try await byte in bytes {
            guard data.count < limit else { throw ManagementError.responseTooLarge }
            data.append(byte)
        }
        return data
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
        self.baseURL = baseURL
        self.key = key
        self.transport = session
    }

    public init(baseURL: URL, key: String, transport: any HTTPTransport) {
        self.baseURL = baseURL
        self.key = key
        self.transport = transport
    }

    public func authFiles() async throws -> AuthFilesResponse {
        try decode(AuthFilesResponse.self, data: await send(path: "auth-files"))
    }

    public func apiCall(_ request: APICallRequest) async throws -> APICallResponse {
        let body: Data
        do {
            body = try JSONEncoder().encode(request)
        } catch {
            throw ManagementError.decoding("Invalid API call request")
        }
        return try decode(APICallResponse.self, data: await send(path: "api-call", body: body))
    }

    public func drainUsageQueue(batchSize: Int = 500, maxBatches: Int = 10) async throws
        -> [UsageRecord]
    {
        try await drainUsageQueueResult(batchSize: batchSize, maxBatches: maxBatches).records
    }

    /// Carries endpoint availability separately from a genuinely empty queue.
    public func drainUsageQueueResult(batchSize: Int = 500, maxBatches: Int = 10) async throws
        -> UsageDrainResult
    {
        let size = max(1, batchSize)
        var records: [UsageRecord] = []
        var completedBatches = 0
        for _ in 0..<max(0, maxBatches) {
            do {
                let data = try await send(
                    path: "usage-queue",
                    query: [URLQueryItem(name: "count", value: String(size))]
                )
                let batch = try decode(UsageQueueBatch.self, data: data)
                completedBatches += 1
                records.append(contentsOf: batch.records)
                if batch.rawCount < size { break }
            } catch ManagementError.http(404) {
                return UsageDrainResult(records: records, available: false)
            } catch {
                // Popped batches cannot be retried; preserve them for local ingestion.
                guard completedBatches > 0 else { throw error }
                return UsageDrainResult(records: records, available: true)
            }
        }
        return UsageDrainResult(records: records, available: true)
    }

    private func decode<T: Decodable>(_ type: T.Type, data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw ManagementError.decoding("Invalid management response")
        }
    }

    private func send(path: String, query: [URLQueryItem] = [], body: Data? = nil) async throws
        -> Data
    {
        guard let valid = BaseURLValidator.validate(baseURL.absoluteString),
            var components = URLComponents(url: valid, resolvingAgainstBaseURL: false)
        else {
            throw ManagementError.invalidBaseURL
        }
        components.path = "/v0/management/" + path
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url else { throw ManagementError.invalidBaseURL }
        var request = URLRequest(url: url)
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        if let body {
            request.httpMethod = "POST"
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch ManagementError.responseTooLarge {
            throw ManagementError.responseTooLarge
        } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            switch error.code {
            case .cannotConnectToHost, .timedOut, .networkConnectionLost, .notConnectedToInternet,
                .cannotFindHost:
                // Localized errors may contain URLs or reflected credentials.
                throw ManagementError.proxyDown("Gateway unavailable (\(error.code.rawValue))")
            default:
                throw ManagementError.proxyDown("Network request failed")
            }
        } catch {
            throw ManagementError.proxyDown("Network request failed")
        }
        guard data.count <= URLSession.islandResponseLimit else {
            throw ManagementError.responseTooLarge
        }
        if response.statusCode == 401 || response.statusCode == 403 {
            throw ManagementError.unauthorized
        }
        guard (200..<300).contains(response.statusCode) else {
            throw ManagementError.http(response.statusCode)
        }
        return data
    }
}
