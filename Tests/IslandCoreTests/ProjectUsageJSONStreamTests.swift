import Foundation
import Testing
@testable import IslandCore

@Suite struct ProjectUsageJSONStreamTests {
    private func parse(_ text: String, chunk: Int = 65_536) -> [ProjectUsageEnvelope] {
        parse(Data(text.utf8), chunk: chunk)
    }
    private func parse(_ data: Data, chunk: Int = 65_536) -> [ProjectUsageEnvelope] {
        var parser = ProjectUsageJSONStream()
        var rows: [ProjectUsageEnvelope] = []
        for offset in stride(from: 0, to: data.count, by: chunk) {
            rows += parser.feed(data.subdata(in: offset..<min(offset + chunk, data.count)))
        }
        return rows
    }
    private func rejected(_ text: String, warning: ProjectUsageParseWarning? = nil) {
        let rows = parse(text + "\n{\"type\":\"recovered\"}\n", chunk: 1)
        #expect(rows.count == 2)
        #expect(rows[0].warning != nil)
        if let warning { #expect(rows[0].warning == warning) }
        #expect(rows[0].fields.isEmpty)
        #expect(rows[1].warning == nil)
        #expect(rows[1].fields == [.type: .string("recovered")])
    }

    @Test func claudeAndCodexMetadata() {
        let claude = #"{"type":"assistant","timestamp":"2026-10-09T12:00:00Z","sessionId":"fake-session","cwd":"/fake/project","message":{"id":"fake-response","usage":{"input_tokens":10,"output_tokens":2,"cache_read_input_tokens":3,"cache_creation_input_tokens":4}}}"#
        let codex = #"{"type":"token_usage_record","ordinal":14,"payload":{"type":"token_count","id":"fake-id","session_id":"fake-session","thread_id":"fake-thread","response_id":"fake-response","cwd":"/fake/project","usage":{"input_tokens":20,"cached_input_tokens":7,"cache_write_input_tokens":3,"output_tokens":2,"reasoning_output_tokens":1,"total_tokens":22},"turn_token_usage":{"input_tokens":9999},"thread_token_usage":{"input_tokens":99999}}}"#
        let rows = parse(claude + "\n" + codex + "\n", chunk: 7)
        #expect(rows.count == 2)
        #expect(rows.allSatisfy { $0.warning == nil })
        #expect(rows[0].fields == [.type: .string("assistant"), .timestamp: .string("2026-10-09T12:00:00Z"),
                                  .sessionId: .string("fake-session"), .cwd: .string("/fake/project"),
                                  .messageId: .string("fake-response"), .messageInputTokens: .integer(10),
                                  .messageOutputTokens: .integer(2), .messageCacheReadInputTokens: .integer(3),
                                  .messageCacheCreationInputTokens: .integer(4)])
        #expect(rows[1].fields == [.type: .string("token_usage_record"), .ordinal: .integer(14),
                                  .payloadType: .string("token_count"), .payloadId: .string("fake-id"),
                                  .payloadSessionId: .string("fake-session"), .payloadThreadId: .string("fake-thread"),
                                  .payloadResponseId: .string("fake-response"), .payloadCwd: .string("/fake/project"),
                                  .payloadInputTokens: .integer(20), .payloadCachedInputTokens: .integer(7),
                                  .payloadCacheWriteInputTokens: .integer(3), .payloadOutputTokens: .integer(2),
                                  .payloadReasoningOutputTokens: .integer(1), .payloadTotalTokens: .integer(22)])
    }

    @Test func giantBodiesBeforeUsageAreSkipped() {
        let body = String(repeating: "private body ", count: 100_000)
        let user = "{\"type\":\"user\",\"message\":{\"content\":\"" + body + "\"}}\n"
        let assistant = "{\"type\":\"assistant\",\"message\":{\"content\":[{\"text\":\"" + body + "\"}],\"id\":\"fake\",\"usage\":{\"input_tokens\":10,\"output_tokens\":2}}}\n"
        let rows = parse(user + assistant)
        #expect(rows.count == 2)
        #expect(rows.allSatisfy { $0.warning == nil })
        #expect(rows[0].fields == [.type: .string("user")])
        #expect(rows[1].fields == [.type: .string("assistant"), .messageId: .string("fake"),
                                  .messageInputTokens: .integer(10), .messageOutputTokens: .integer(2)])
        #expect(rows[0].byteLength == user.utf8.count)
        #expect(rows[1].byteLength == assistant.utf8.count)
        #expect(!String(describing: rows).contains("private body"))
    }

    @Test func decodedUnicodeAtEveryByteAndRandomCuts() {
        let escape = String(UnicodeScalar(92)) + "u"
        let text = (#"{"type":"é水😀"# + escape + "D83D" + escape + "DE00" +
                    #"\"\\\/\b\f\n\r\t\u0000","ignored":"￿﷐","payload":{"cwd":null}}"#) + "\r\n"
        let expected: [ProjectUsageField: ProjectUsageScalar] = [.type: .string("é水😀😀\"\\/\u{8}\u{c}\n\r\t\0"), .payloadCwd: .null]
        #expect(parse(text, chunk: 1)[0].fields == expected)
        let bytes = Data(text.utf8)
        for seed in 1...20 {
            var random = UInt64(seed)
            var parser = ProjectUsageJSONStream()
            var rows: [ProjectUsageEnvelope] = []
            var offset = 0
            while offset < bytes.count {
                random = random &* 6_364_136_223_846_793_005 &+ 1
                let end = min(bytes.count, offset + Int(random % 19) + 1)
                rows += parser.feed(bytes.subdata(in: offset..<end))
                offset = end
            }
            #expect(rows.count == 1)
            #expect(rows[0].warning == nil)
            #expect(rows[0].fields == expected)
        }
    }

    @Test func malformedUnicodeAndEscapes() {
        for string in [#"\uD800"#, #"\uDC00"#, #"\uD800A"#, #"\uD800x"#, #"\uD800\\uDC00"#,
                       #"\uD800\n"#, #"\u12xz"#, #"\x"#, "\t", "\r", "\u{1}"] {
            rejected("{\"type\":\"valid prefix\",\"unknown\":\"" + string + "\"}", warning: .malformed)
        }
        let badUTF8: [[UInt8]] = [[0x80], [0xC0, 0xAF], [0xC1, 0xBF], [0xC2, 0x20], [0xE0, 0x80, 0x80],
                                  [0xED, 0xA0, 0x80], [0xF0, 0x80, 0x80, 0x80], [0xF4, 0x90, 0x80, 0x80],
                                  [0xF5, 0x80, 0x80, 0x80], [0xE2, 0x82], [0xFF]]
        for bytes in badUTF8 {
            let data = Data("{\"type\":\"prefix\",\"unknown\":\"".utf8) + Data(bytes) + Data("\"}\n{}\n".utf8)
            let rows = parse(data, chunk: 1)
            #expect(rows[0].warning == .malformed)
            #expect(rows[0].fields.isEmpty)
            #expect(rows[1].warning == nil)
        }
        // Unicode noncharacters are valid scalar values in JSON, not malformed UTF-8.
        #expect(parse("{\"unknown\":\"\u{FFFF}\u{10FFFF}\"}\n", chunk: 1)[0].warning == nil)
    }

    @Test func physicalBoundariesAndReset() {
        let rows = parse("\n\r\n \t\r\n{}\r\n{\"cwd\":null}\n\n", chunk: 1)
        #expect(rows.map(\.byteLength) == [1, 2, 4, 4, 13, 1])
        #expect(rows.allSatisfy { $0.warning == nil })
        #expect(rows[4].fields == [.cwd: .null])
        #expect(rows.enumerated().filter { $0.offset != 4 }.allSatisfy { $0.element.fields.isEmpty })
        var parser = ProjectUsageJSONStream()
        #expect(!parser.unfinished)
        #expect(parser.feed(Data("{\"type\":\"partial\\uD83D".utf8)).isEmpty)
        #expect(parser.unfinished)
        #expect(parser.feed(Data()).isEmpty)
        #expect(parser.unfinished)
        parser.reset()
        #expect(!parser.unfinished)
        let recovered = parser.feed(Data("{}\n".utf8))
        #expect(recovered[0].byteLength == 3)
        #expect(recovered[0].warning == nil)
        #expect(!parser.unfinished)
        #expect(parser.feed(Data("{}".utf8)).isEmpty)
        #expect(parser.unfinished) // Complete JSON still needs the physical LF commit boundary.
        #expect(parser.feed(Data("\n".utf8))[0].byteLength == 3)
        #expect(parser.feed(Data(" \t".utf8)).isEmpty)
        #expect(parser.unfinished)
    }

    @Test func grammarRejectsWholeRecordsAndRecovers() {
        for value in ["{} junk", "{}{}", "[]", "null", "1", "{", "{\"type\":\"prefix\"",
                      "{\"type\":\"prefix\",}", "{\"type\" \"prefix\"}", "{\"type\":}", "{,}",
                      "{\"x\":[1,]}", "{\"x\":[,1]}", "{\"x\":[1 2]}", "{\"x\":truefalse}",
                      "{\"x\":tru}", "{\"x\":01}", "{\"x\":+1}", "{\"x\":.1}", "{\"x\":1.}",
                      "{\"x\":1e}", "{\"x\":1e+}", "{\"x\":--1}", "{\"x\":[}", "{\"x\":{]}"] {
            rejected(value, warning: .malformed)
        }
        for value in ["{}", "{\"x\":[null,true,false,-0,0,1.25,-1.25e-42,1E+42,{},[]]}",
                      "{\"message\":false}", "{\"payload\":null}", "{\"message\":{\"usage\":[]}}"] {
            #expect(parse(value + "\n", chunk: 1)[0].warning == nil)
        }
        let rows = parse(String(repeating: "{}\n", count: 2000))
        #expect(rows.count == 2000)
        #expect(rows.allSatisfy { $0.byteLength == 3 && $0.warning == nil && $0.fields.isEmpty })
    }

    @Test func relevantDuplicatesIncludingEscapedAncestors() {
        let unicodeEscape = String(UnicodeScalar(92)) + "u"
        for value in [
            "{\"type\":\"a\",\"" + unicodeEscape + "0074ype\":\"b\"}",
            "{\"message\":{},\"" + unicodeEscape + "006dessage\":{}}",
            "{\"payload\":{},\"" + unicodeEscape + "0070ayload\":{}}",
            "{\"message\":{\"usage\":{},\"" + unicodeEscape + "0075sage\":{}}}",
            "{\"payload\":{\"usage\":{\"input_tokens\":1,\"" + unicodeEscape + "0069nput_tokens\":2}}}",
            #"{"type":"a","type":"b"}"#,
                      #"{"message":{"id":"a","id":"b"}}"#,
                      #"{"message":{},"message":{}}"#,
                      #"{"message":false,"message":{}}"#,
                      #"{"payload":{},"payload":{}}"#,
                      #"{"message":{"usage":{},"usage":{}}}"#,
                      #"{"payload":{"usage":{},"usage":{}}}"#,
                      #"{"payload":{"usage":{"input_tokens":1,"input_tokens":2}}}"#,
                      #"{"payload":{"cwd":null,"cwd":"/fake"}}"#] {
            rejected(value, warning: .invalidSelectedField)
        }
        let unknown = #"{"x":1,"x":2,"other":{"type":"a","type":"b","message":{},"message":{}},"message":{"content":"a","content":"b"}}"#
        #expect(parse(unknown + "\n", chunk: 1)[0].warning == nil)
    }

    @Test func membersCannotImpersonatePaths() {
        let text = #"{"message.id":"bad","message.usage.input_tokens":999,"other":{"message":{"id":"bad","usage":{"input_tokens":999}}},"message":[{"id":"bad","usage":{"input_tokens":999}}],"payload":{"usage":[{"input_tokens":999}],"other":{"id":"bad"}}}"#
        let row = parse(text + "\n", chunk: 1)[0]
        #expect(row.warning == nil)
        #expect(row.fields.isEmpty)
        let literalChild = #"{"message":{"usage.input_tokens":999,"id":"good","usage":{"input_tokens":1}}}"#
        #expect(parse(literalChild + "\n")[0].fields == [.messageId: .string("good"), .messageInputTokens: .integer(1)])
    }

    @Test func selectedCountersAreStrict() {
        for value in ["-1", "-0", "1.0", "1e0", "true", "false", "\"1\"", "null", "9223372036854775808",
                      "18446744073709551615", "999999999999999999999999", "{}", "[]"] {
            rejected("{\"type\":\"prefix\",\"message\":{\"usage\":{\"input_tokens\":" + value + "}}}", warning: .invalidSelectedField)
            rejected("{\"ordinal\":" + value + "}", warning: .invalidSelectedField)
        }
        let row = parse("{\"message\":{\"usage\":{\"input_tokens\":0,\"output_tokens\":9223372036854775807}}}\n")[0]
        #expect(row.warning == nil)
        #expect(row.fields == [.messageInputTokens: .integer(0), .messageOutputTokens: .integer(Int.max)])
        for value in ["42", "true", "false", "{}", "[]"] {
            rejected("{\"cwd\":" + value + "}", warning: .invalidSelectedField)
        }
    }

    @Test func selectedStringAndDepthCaps() {
        let accepted = String(repeating: "😀", count: 1024)
        let row = parse("{\"cwd\":\"" + accepted + "\"}\n", chunk: 1)[0]
        #expect(row.warning == nil)
        #expect(row.fields[.cwd] == .string(accepted))
        rejected("{\"type\":\"prefix\",\"cwd\":\"" + accepted + "a\"}", warning: .invalidSelectedField)
        let escape = String(UnicodeScalar(92)) + "u"
        let escaped = String(repeating: escape + "D83D" + escape + "DE00", count: 1024)
        #expect(parse("{\"cwd\":\"" + escaped + "\"}\n", chunk: 1)[0].warning == nil)
        rejected("{\"cwd\":\"" + escaped + #"a"# + "\"}", warning: .invalidSelectedField)
        let depth64 = "{\"x\":" + String(repeating: "[", count: 63) + "0" + String(repeating: "]", count: 63) + "}"
        #expect(parse(depth64 + "\n", chunk: 1)[0].warning == nil)
        let depth65 = "{\"type\":\"prefix\",\"x\":" + String(repeating: "[", count: 64) + "0" + String(repeating: "]", count: 64) + "}"
        rejected(depth65, warning: .depthExceeded)
        let objects64 = String(repeating: "{\"x\":", count: 63) + "{}" + String(repeating: "}", count: 63)
        #expect(parse(objects64 + "\n", chunk: 1)[0].warning == nil)
        rejected("{\"x\":" + objects64 + "}", warning: .depthExceeded)
    }

    @Test func giantUnknownKeysNumbersAndLegacyCounters() {
        let key = String(repeating: "unknown", count: 150_000)
        let number = "1" + String(repeating: "2", count: 1_000_000)
        let text = "{\"" + key + "\":" + number + ",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":{\"input_tokens\":999}}},\"type\":\"event_msg\"}\n"
        let row = parse(text)[0]
        #expect(row.warning == nil)
        #expect(row.fields == [.type: .string("event_msg"), .payloadType: .string("token_count")])
        #expect(row.byteLength == text.utf8.count)
        // A giant skipped number is still grammar-validated, including its final byte.
        let bad = "{\"type\":\"prefix\",\"x\":" + number + "x}\n"
        let rejectedRow = parse(bad)[0]
        #expect(rejectedRow.warning == .malformed)
        #expect(rejectedRow.fields.isEmpty)
    }
}
