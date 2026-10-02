import Foundation
import Testing

@testable import IslandCore

private let fixedNow = Fixtures.referenceNow
private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
    try JSONDecoder().decode(type, from: Data(json.utf8))
}
private func fixture<T: Decodable>(_ type: T.Type, _ name: String) throws -> T {
    try JSONDecoder().decode(type, from: Fixtures.data(name))
}
private func auth(_ json: String) throws -> AuthFilesResponse {
    try decode(AuthFilesResponse.self, "{\"files\":[" + json + "]}")
}

@Test func allFixturesDecode() throws {
    let files = try fixture(AuthFilesResponse.self, "auth-files")
    #expect(files.files.count == 5)
    #expect(files.files[0].cooldowns == nil)
    #expect(files.files[0].success == 999)
    #expect(files.files[0].quota?.signals["Anthropic-Ratelimit-Unified-7d-Utilization"] == "0.18")
    #expect(files.files[0].quota?.observedAt != nil)
    let queue = try fixture(UsageQueueBatch.self, "usage-queue")
    #expect(queue.rawCount == 13)
    #expect(queue.records.count == 12)
    #expect(queue.records[0].tokens?.inputTokens == 1000)
    #expect(queue.records[0].latencyMS == 1234.5)
    for name in ["api-call-claude-usage", "api-call-codex-usage", "api-call-error"] {
        #expect(try fixture(APICallResponse.self, name).statusCode != nil)
    }
    // DTOs neither retain nor expose any sensitive wire fields.
    let reflection = String(reflecting: queue.records)
    #expect(!reflection.contains("fake-sensitive"))
    #expect(!reflection.contains("192.0.2.1"))
}
@Test func lenientMalformedFields() throws {
    let response = try decode(
        AuthFilesResponse.self,
        #"{"observed_at":null,"files":[{"id":4,"disabled":"true","quota":{"signals":{"a":12,"b":null}},"recent_requests":false,"cooldowns":null,"success":"Infinity","failed":"2.9"},"junk",null,{}]}"#
    )
    #expect(response.files.count == 2)
    #expect(response.files[0].disabled == true)
    #expect(response.files[0].success == nil)
    #expect(response.files[0].failed == 2)
    #expect(response.files[0].quota?.signals == ["a": "12.0"])
    #expect(response.files[0].recentRequests == nil)
    let queue = try decode(
        UsageQueueBatch.self,
        #"[null,3,true,[],"junk",{"tokens":{"input_tokens":{},"total_tokens":"1e100"}}]"#)
    #expect(queue.rawCount == 6)
    #expect(queue.records.count == 1)
    #expect(queue.records.first?.tokens?.totalTokens == nil)
}
@Test(arguments: [
    "2026-10-02T09:15:04.123456789Z", "2026-10-02T09:15:04Z", "2026-10-02T09:15:04+08:00",
    "2026-10-02T09:15:04.1Z", "2026-10-02T09:15:04.123456789+08:00",
])
func tolerantDates(_ string: String) { #expect(APIDateParser.parse(string) != nil) }
@Test func datePrecisionAndInvalid() {
    #expect(APIDateParser.parse("nonsense") == nil)
    let date = APIDateParser.parse("2026-10-02T09:15:04.123456789Z")!
    #expect(
        abs(date.timeIntervalSince(APIDateParser.parse("2026-10-02T09:15:04Z")!) - 0.123) < 0.001)
    #expect(
        APIDateParser.parse("2026-10-02T09:15:04+08:00")
            == APIDateParser.parse("2026-10-02T01:15:04Z"))
}
@Test func claudeHeaders() {
    let windows = HeaderQuotaParser.windows(
        provider: .claude,
        signals: [
            "Anthropic-Ratelimit-Unified-7d-Utilization": "0.18",
            "ANTHROPIC-RATELIMIT-UNIFIED-5H-UTILIZATION": "0.42",
            "anthropic-ratelimit-unified-5h-reset": "1790950000",
            "anthropic-ratelimit-unified-7d-opus-utilization": "0.9",
            "anthropic-ratelimit-unified-7d_sonnet-utilization": "0.1",
            "anthropic-ratelimit-unified-2h-utilization": "0.5",
            "Retry-After": "10", "anthropic-ratelimit-unified-status": "allowed",
        ], observedAt: nil)
    #expect(windows.map(\.label) == ["5h", "Week", "Week · Opus", "Week · Sonnet"])
    #expect(windows[0].usedFraction == 0.42)
    #expect(windows[0].resetsAt == Date(timeIntervalSince1970: 1_790_950_000))
    #expect(windows[2].id == "claude.7d_opus")
    #expect(HeaderQuotaParser.plan(provider: .claude, signals: [:]) == nil)
}
@Test func codexHeaders() {
    let windows = HeaderQuotaParser.windows(
        provider: .codex,
        signals: [
            "X-Codex-Primary-Used-Percent": "23", "x-codex-primary-window-minutes": "300",
            "x-codex-primary-reset-at": "1790950000", "x-codex-primary-reset-after-seconds": "60",
            "x-codex-secondary-used-percent": "80", "x-codex-secondary-window-minutes": "10080",
            "x-codex-secondary-reset-after-seconds": "100",
        ], observedAt: fixedNow)
    #expect(windows.map(\.label) == ["5h", "Week"])
    #expect(windows[0].usedFraction == 0.23)
    #expect(windows[0].resetsAt == Date(timeIntervalSince1970: 1_790_950_000))
    #expect(windows[1].resetsAt == fixedNow.addingTimeInterval(100))
    #expect(
        HeaderQuotaParser.plan(provider: .codex, signals: ["X-Codex-Plan-Type": "pro"]) == "pro")
    #expect(
        HeaderQuotaParser.windows(
            provider: .gemini, signals: ["x-codex-primary-used-percent": "1"], observedAt: fixedNow
        ).isEmpty)
    #expect(
        HeaderQuotaParser.windows(
            provider: .codex, signals: ["x-codex-primary-reset-after-seconds": "60"],
            observedAt: nil
        ).isEmpty)
}
@Test(arguments: [(120, "2h"), (1440, "1d"), (2880, "2d"), (90, "90m")])
func minuteLabels(_ pair: (Int, String)) {
    let windows = HeaderQuotaParser.windows(
        provider: .codex,
        signals: [
            "x-codex-primary-used-percent": "1", "x-codex-primary-window-minutes": String(pair.0),
        ], observedAt: nil)
    #expect(windows.first?.label == pair.1)
}
@Test func liveFixturesAndErrors() throws {
    let claude = LiveQuotaFetcher.parse(
        provider: .claude, response: try fixture(APICallResponse.self, "api-call-claude-usage"),
        now: fixedNow)
    #expect(claude?.windows.count == 3)
    #expect(claude?.windows.first?.usedFraction == 0.42)
    #expect(claude?.windows.map(\.label) == ["5h", "Week", "Week · Opus"])
    let codex = LiveQuotaFetcher.parse(
        provider: .codex, response: try fixture(APICallResponse.self, "api-call-codex-usage"),
        now: fixedNow)
    #expect(codex?.plan == "plus")
    #expect(codex?.windows.first?.usedFraction == 0.23)
    #expect(codex?.windows[0].resetsAt == fixedNow.addingTimeInterval(3600))
    #expect(codex?.windows[1].resetsAt == fixedNow.addingTimeInterval(86400))
    #expect(
        LiveQuotaFetcher.parse(
            provider: .claude, response: try fixture(APICallResponse.self, "api-call-error"),
            now: fixedNow) == nil)
    #expect(
        LiveQuotaFetcher.parse(
            provider: .claude,
            response: try decode(APICallResponse.self, #"{"status_code":200,"body":"broken"}"#),
            now: fixedNow) == nil)
    #expect(
        LiveQuotaFetcher.parse(
            provider: .claude,
            response: try decode(APICallResponse.self, #"{"status_code":200,"body":"{}"}"#),
            now: fixedNow) == nil)
}
@Test func liveCamelCaseAndRequests() throws {
    let json =
        #"{"status_code":200,"body":"{\"planType\":\"pro\",\"rateLimit\":{\"primaryWindow\":{\"usedPercent\":55,\"limitWindowSeconds\":7200,\"resetAfterSeconds\":120}}}"}"#
    let live = LiveQuotaFetcher.parse(
        provider: .codex, response: try decode(APICallResponse.self, json), now: fixedNow)
    #expect(live?.plan == "pro")
    #expect(live?.windows.first?.label == "2h")
    #expect(live?.windows.first?.resetsAt == fixedNow.addingTimeInterval(120))
    let files = try fixture(AuthFilesResponse.self, "auth-files").files
    let request = LiveQuotaFetcher.request(for: files[2])
    #expect(request?.header["Chatgpt-Account-Id"] == "fake-account-0000")
    #expect(request?.header["Authorization"] == "Bearer $TOKEN$")
    #expect(LiveQuotaFetcher.request(for: files[0])?.header["anthropic-beta"] == "oauth-2025-04-20")
    #expect(LiveQuotaFetcher.request(for: files[3]) == nil)
    #expect(LiveQuotaFetcher.request(for: files[4]) == nil)
    #expect(LiveQuotaFetcher.request(for: try auth(#"{"provider":"claude"}"#).files[0]) == nil)
    let data = try JSONEncoder().encode(request!)
    #expect(String(decoding: data, as: UTF8.self).contains("auth_index"))
}
@Test func mappingFixtureTrafficSortingAndHealth() throws {
    let accounts = AccountMapper.accounts(
        from: try fixture(AuthFilesResponse.self, "auth-files"), live: [:], now: fixedNow)
    #expect(
        accounts.map(\.id) == [
            "fake-alice", "fake-charlie", "fake-bob", "fake-gemini", "fake-disabled-0000",
        ])
    #expect(accounts[0].requestsLastHour == 66)
    #expect(accounts[0].failedLastHour == 6)
    #expect(accounts[0].health == .ok)
    #expect(
        accounts[2].health
            == .rateLimited(until: fixedNow.addingTimeInterval(1800), reason: "quota"))
    #expect(accounts.last?.health == .disabled)
    #expect(accounts[1].plan == "plus")
    #expect(accounts[3].quotaSource == .none)
}
@Test func mappingLivePrecedenceAndStaleness() throws {
    let response = try fixture(AuthFilesResponse.self, "auth-files")
    let window = QuotaWindow(
        id: "test", label: "Test", usedFraction: 0.8, resetsAt: fixedNow.addingTimeInterval(600))
    let live = LiveQuota(windows: [window], plan: "pro", observedAt: fixedNow)
    let mapped = AccountMapper.accounts(from: response, live: ["fake-codex-1": live], now: fixedNow)
    let account = mapped.first { $0.id == "fake-charlie" }!
    #expect(account.windows == [window])
    #expect(account.plan == "pro")
    #expect(account.quotaSource == .live(observedAt: fixedNow))
    let stale = AccountMapper.accounts(
        from: response, live: ["fake-codex-1": live], now: fixedNow.addingTimeInterval(900)
    ).first { $0.id == "fake-charlie" }!
    #expect(stale.windows.first?.id == "codex.primary")
    #expect(stale.quotaSource != .live(observedAt: fixedNow))
}
@Test func healthPrecedenceAndLabelFallbacks() throws {
    let files = try auth(
        #"{"id":"a","provider":"claude","status":"error","status_message":"Oops","unavailable":true,"next_retry_after":"2026-10-02T13:00:00Z","cooldowns":[{"reason":"cooldown","retry_at":"2026-10-02T14:00:00Z"},{"reason":"quota","retry_at":"2026-10-02T15:00:00Z"}]}"#
    )
    #expect(
        AccountMapper.accounts(from: files, live: [:], now: fixedNow)[0].health
            == .rateLimited(until: fixedNow.addingTimeInterval(10800), reason: "quota"))
    var changed = files
    changed.files[0].cooldowns = nil
    #expect(
        AccountMapper.accounts(from: changed, live: [:], now: fixedNow)[0].health
            == .rateLimited(until: fixedNow.addingTimeInterval(3600), reason: nil))
    changed.files[0].unavailable = false
    #expect(
        AccountMapper.accounts(from: changed, live: [:], now: fixedNow)[0].health == .error("Oops"))
    changed.files[0].disabled = true
    #expect(AccountMapper.accounts(from: changed, live: [:], now: fixedNow)[0].health == .disabled)
    for (field, value, expected) in [
        ("email", "mail", "mail"), ("label", "label", "label"), ("account", "account", "account"),
        ("name", "private-file.json", "Unknown"), ("id", "fake-abcd", "Unknown · abcd")
    ] {
        let response = try auth("{\"\(field)\":\"\(value)\"}")
        #expect(AccountMapper.accounts(from: response, live: [:], now: fixedNow)[0].label == expected)
    }
}
@Test(arguments: ["claude", "codex"])
func headerLimitHealth(_ provider: String) throws {
    let signals =
        provider == "claude"
        ? #"{"Anthropic-Ratelimit-Unified-Status":"rejected","Anthropic-Ratelimit-Unified-5h-Utilization":"1","Anthropic-Ratelimit-Unified-5h-Reset":"1790946000"}"#
        : #"{"X-Codex-Limit-Reached":"true","X-Codex-Primary-Used-Percent":"100","X-Codex-Primary-Reset-At":"1790946000"}"#
    let response = try auth("{\"provider\":\"\(provider)\",\"quota\":{\"signals\":\(signals)}}")
    #expect(
        AccountMapper.accounts(from: response, live: [:], now: fixedNow)[0].health
            == .rateLimited(
                until: Date(timeIntervalSince1970: 1_790_946_000), reason: "limit reached"))
}
@Test(arguments: [
    "http://127.0.0.1:8317", " http://localhost:8317/ \n", "http://[::1]:8317",
    "https://example.com", "https://example.com/",
])
func validBaseURLs(_ url: String) { #expect(BaseURLValidator.validate(url) != nil) }
@Test(arguments: [
    "http://example.com", "ftp://localhost", "http://127.0.0.1/path", "https://example.com?a=1",
    "https://example.com#frag", "https://u:p@example.com", "localhost:8317", "",
    "http://127.0.0.1.evil.com", "http://0.0.0.0", "https://example.com:0",
    "https://example.com:65536",
])
func invalidBaseURLs(_ url: String) { #expect(BaseURLValidator.validate(url) == nil) }
@Test func normalizedBaseURL() {
    #expect(
        BaseURLValidator.validate(" http://localhost:8317/ ")?.absoluteString
            == "http://localhost:8317")
}
@Test func inMemoryKeyStore() throws {
    let store = InMemoryKeyStore()
    #expect(try store.read() == nil)
    try store.save(" \n fake-key \t")
    #expect(try store.read() == "fake-key")
    #expect(throws: KeyStoreError.emptyKey) { try store.save(" \n ") }
    #expect(try store.read() == "fake-key")
    try store.delete()
    #expect(try store.read() == nil)
}

@Test func accountLabelPrefersTrimmedEmailOverAllOtherFields() throws {
  let response = try auth(
    #"{"email":"  person@example.com \n","label":"Label","account":"Account.json","name":"private.json","id":"identity-1234","provider":"claude"}"#
  )
  #expect(
    AccountMapper.accounts(from: response, live: [:], now: fixedNow)[0].label
      == "person@example.com")
}

@Test func accountLabelFallsBackToTrimmedLabelWhenEmailIsBlank() throws {
  let response = try auth(
    #"{"email":" \t","label":"  Team Label  ","account":"Account.json","name":"private.json","id":"identity-1234","provider":"claude"}"#
  )
  #expect(AccountMapper.accounts(from: response, live: [:], now: fixedNow)[0].label == "Team Label")
}

@Test func accountLabelFallsBackToTrimmedAccountWithoutJsonSuffix() throws {
  let response = try auth(
    #"{"email":" ","label":"\n","account":"  Team Account .JSON  ","name":"private.json","id":"identity-1234","provider":"claude"}"#
  )
  #expect(
    AccountMapper.accounts(from: response, live: [:], now: fixedNow)[0].label == "Team Account")
}

@Test func accountLabelFallsBackToProviderAndTrimmedIDNeverRawName() throws {
  let response = try auth(
    #"{"email":" ","label":"\n","account":" .json ","name":"private.json","id":"  identity-1234 \n","auth_index":"index-5678","provider":"claude"}"#
  )
  #expect(
    AccountMapper.accounts(from: response, live: [:], now: fixedNow)[0].label == "Claude · 1234")
}

@Test func accountLabelFallsBackToAuthIndexWhenIDIsBlank() throws {
  let response = try auth(
    #"{"id":" \t","auth_index":"  index-5678 \n","name":"private.json","provider":"codex"}"#)
  #expect(
    AccountMapper.accounts(from: response, live: [:], now: fixedNow)[0].label == "Codex · 5678")
}

@Test func accountLabelWithNoIdentityUsesOnlyProviderNotRawName() throws {
  let response = try auth(#"{"name":"private.json","provider":"gemini"}"#)
  #expect(AccountMapper.accounts(from: response, live: [:], now: fixedNow)[0].label == "Gemini")
}

@Test func onlyEmptyNormalizedProviderIsUnknown() {
  for raw in ["", " \t\n "] {
    let provider = Provider(raw: raw)
    #expect(provider == .other(""))
    #expect(provider.isUnknown)
    #expect(provider.displayName == "Unknown")
  }
  for provider in [
    Provider.claude, .codex, .gemini, .other("unknown"), .other("custom"), .other(" "),
  ] {
    #expect(!provider.isUnknown)
  }
  #expect(Provider(raw: " CUSTOM ") == .other("custom"))
  #expect(!Provider(raw: "unknown").isUnknown)
}
