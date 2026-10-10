import Foundation

enum ProjectUsageScalar: Equatable, Sendable {
    case string(String), integer(Int), null
}

enum ProjectUsageField: String, CaseIterable, Sendable {
    case type, timestamp, sessionId, cwd, ordinal
    case messageId = "message.id"
    case messageInputTokens = "message.usage.input_tokens"
    case messageOutputTokens = "message.usage.output_tokens"
    case messageCacheReadInputTokens = "message.usage.cache_read_input_tokens"
    case messageCacheCreationInputTokens = "message.usage.cache_creation_input_tokens"
    case payloadType = "payload.type"
    case payloadId = "payload.id"
    case payloadSessionId = "payload.session_id"
    case payloadThreadId = "payload.thread_id"
    case payloadResponseId = "payload.response_id"
    case payloadCwd = "payload.cwd"
    case payloadInputTokens = "payload.usage.input_tokens"
    case payloadCachedInputTokens = "payload.usage.cached_input_tokens"
    case payloadCacheWriteInputTokens = "payload.usage.cache_write_input_tokens"
    case payloadOutputTokens = "payload.usage.output_tokens"
    case payloadReasoningOutputTokens = "payload.usage.reasoning_output_tokens"
    case payloadTotalTokens = "payload.usage.total_tokens"

    fileprivate var isInteger: Bool {
        self == .ordinal || rawValue.contains(".usage.")
    }
}

enum ProjectUsageParseWarning: Equatable, Sendable {
    case malformed, invalidSelectedField, depthExceeded
}

struct ProjectUsageEnvelope: Sendable {
    var fields: [ProjectUsageField: ProjectUsageScalar]
    var byteLength: Int
    var warning: ProjectUsageParseWarning?
}

/// Validates every byte, but stores only whitelisted metadata. Physical LF is the
/// commit boundary: a valid prefix never escapes an invalid or unfinished record.
struct ProjectUsageJSONStream: Sendable {
    private enum Scope: Sendable { case root, message, messageUsage, payload, payloadUsage, ignored }
    private enum Phase: Sendable {
        case objectFirst, objectKey, colon, objectValue, objectEnd
        case arrayFirst, arrayValue, arrayEnd
    }
    private struct Frame: Sendable {
        var scope: Scope
        var phase: Phase
        var key: String?
        var seen: Set<String> = []
    }
    private enum StringMode: Sendable {
        case normal, escape, hex, surrogateSlash, surrogateU
    }
    private struct StringToken: Sendable {
        var isKey: Bool
        var field: ProjectUsageField?
        var text = ""
        var length = 0
        var keyTooLong = false
        var mode: StringMode = .normal
        var hexValue: UInt32 = 0
        var hexCount = 0
        var highSurrogate: UInt32?
        var utfRemaining = 0
        var utfValue: UInt32 = 0
        var utfMinimum: UInt32 = 0
    }
    private enum NumberPhase: Sendable { case sign, zero, integer, dot, fraction, exponent, exponentSign, exponentDigits }
    private struct NumberToken: Sendable {
        var phase: NumberPhase
        var field: ProjectUsageField?
        var text: String
        var integerOnly = true
        var accepting: Bool {
            switch phase {
            case .zero, .integer, .fraction, .exponentDigits: true
            default: false
            }
        }
    }
    private struct LiteralToken: Sendable {
        var expected: [UInt8]
        var index: Int
        var field: ProjectUsageField?
    }
    private enum Token: Sendable {
        case string(StringToken), number(NumberToken), literal(LiteralToken)
    }
    private var frames: [Frame] = []
    private var token: Token?
    private var fields: [ProjectUsageField: ProjectUsageScalar] = [:]
    private var warning: ProjectUsageParseWarning?
    private var byteLength = 0
    private var started = false
    private var completed = false

    init() {}
    var unfinished: Bool { byteLength != 0 }

    mutating func reset() { self = Self() }

    mutating func feed(_ data: Data) -> [ProjectUsageEnvelope] {
        var output: [ProjectUsageEnvelope] = []
        for byte in data {
            byteLength += 1
            if byte == 10 {
                finishTokenAtBoundary()
                if warning == nil, started, !completed { fail(.malformed) }
                output.append(.init(fields: warning == nil ? fields : [:], byteLength: byteLength, warning: warning))
                reset()
            } else if warning == nil {
                consume(byte)
            }
        }
        return output
    }

    private mutating func fail(_ reason: ProjectUsageParseWarning) {
        warning = reason
        fields.removeAll(keepingCapacity: false)
        frames.removeAll(keepingCapacity: false)
        token = nil
    }

    private static func whitespace(_ byte: UInt8) -> Bool { byte == 32 || byte == 9 || byte == 13 }
    private static func delimiter(_ byte: UInt8) -> Bool {
        whitespace(byte) || byte == 44 || byte == 93 || byte == 125
    }

    private mutating func finishTokenAtBoundary() {
        guard warning == nil, let token else { return }
        switch token {
        case .number(let number): finish(number)
        case .literal(let literal):
            if literal.index == literal.expected.count { finish(literal) } else { fail(.malformed) }
        case .string: fail(.malformed)
        }
    }

    private mutating func consume(_ byte: UInt8) {
        if let current = token {
            switch current {
            case .string(var string):
                consumeString(byte, &string)
                return
            case .number(var number):
                if Self.delimiter(byte) {
                    finish(number)
                    if warning == nil { consume(byte) }
                } else {
                    consumeNumber(byte, &number)
                    if warning == nil { token = .number(number) }
                }
                return
            case .literal(var literal):
                if literal.index < literal.expected.count {
                    guard byte == literal.expected[literal.index] else { fail(.malformed); return }
                    literal.index += 1
                    token = .literal(literal)
                } else if Self.delimiter(byte) {
                    finish(literal)
                    if warning == nil { consume(byte) }
                } else { fail(.malformed) }
                return
            }
        }
        if Self.whitespace(byte) { return }
        guard started else {
            guard byte == 123 else { fail(.malformed); return }
            started = true
            push(.root, .objectFirst)
            return
        }
        guard !completed, let frame = frames.last else { fail(.malformed); return }
        switch frame.phase {
        case .objectFirst, .objectKey:
            if byte == 125, frame.phase == .objectFirst { closeContainer(); return }
            guard byte == 34 else { fail(.malformed); return }
            token = .string(.init(isKey: true))
        case .colon:
            guard byte == 58 else { fail(.malformed); return }
            frames[frames.count - 1].phase = .objectValue
        case .objectValue: beginValue(byte, field: selectedField(frame.scope, frame.key), scope: childScope(frame.scope, frame.key))
        case .objectEnd:
            if byte == 125 { closeContainer() }
            else if byte == 44 { frames[frames.count - 1].phase = .objectKey }
            else { fail(.malformed) }
        case .arrayFirst, .arrayValue:
            if byte == 93, frame.phase == .arrayFirst { closeContainer(); return }
            beginValue(byte, field: nil, scope: .ignored)
        case .arrayEnd:
            if byte == 93 { closeContainer() }
            else if byte == 44 { frames[frames.count - 1].phase = .arrayValue }
            else { fail(.malformed) }
        }
    }

    private mutating func push(_ scope: Scope, _ phase: Phase) {
        guard frames.count < 64 else { fail(.depthExceeded); return }
        frames.append(.init(scope: scope, phase: phase))
    }
    private mutating func closeContainer() {
        frames.removeLast()
        if frames.isEmpty { completed = true }
    }
    private mutating func beginValue(_ byte: UInt8, field: ProjectUsageField?, scope: Scope) {
        let index = frames.count - 1
        frames[index].phase = frames[index].phase == .objectValue ? .objectEnd : .arrayEnd
        if byte == 123 || byte == 91 {
            guard field == nil else { fail(.invalidSelectedField); return }
            push(byte == 123 ? scope : .ignored, byte == 123 ? .objectFirst : .arrayFirst)
        } else if byte == 34 {
            guard field?.isInteger != true else { fail(.invalidSelectedField); return }
            token = .string(.init(isKey: false, field: field))
        } else if byte == 45 || (48...57).contains(byte) {
            guard field == nil || field?.isInteger == true else { fail(.invalidSelectedField); return }
            token = .number(.init(phase: byte == 45 ? .sign : byte == 48 ? .zero : .integer,
                                  field: field, text: field == nil ? "" : String(UnicodeScalar(byte))))
        } else if byte == 110 || byte == 116 || byte == 102 {
            guard field == nil || (byte == 110 && field?.isInteger == false) else { fail(.invalidSelectedField); return }
            let expected = Array((byte == 110 ? "null" : byte == 116 ? "true" : "false").utf8)
            token = .literal(.init(expected: expected, index: 1, field: field))
        } else { fail(.malformed) }
    }

    private func selectedField(_ scope: Scope, _ key: String?) -> ProjectUsageField? {
        guard let key else { return nil }
        // Resolve members individually; a literal period in a root key cannot impersonate a path.
        switch scope {
        case .root:
            switch key {
            case "type": return .type
            case "timestamp": return .timestamp
            case "sessionId": return .sessionId
            case "cwd": return .cwd
            case "ordinal": return .ordinal
            default: return nil
            }
        case .message: return key == "id" ? .messageId : nil
        case .payload:
            switch key {
            case "type": return .payloadType
            case "id": return .payloadId
            case "session_id": return .payloadSessionId
            case "thread_id": return .payloadThreadId
            case "response_id": return .payloadResponseId
            case "cwd": return .payloadCwd
            default: return nil
            }
        case .messageUsage:
            switch key {
            case "input_tokens": return .messageInputTokens
            case "output_tokens": return .messageOutputTokens
            case "cache_read_input_tokens": return .messageCacheReadInputTokens
            case "cache_creation_input_tokens": return .messageCacheCreationInputTokens
            default: return nil
            }
        case .payloadUsage:
            switch key {
            case "input_tokens": return .payloadInputTokens
            case "cached_input_tokens": return .payloadCachedInputTokens
            case "cache_write_input_tokens": return .payloadCacheWriteInputTokens
            case "output_tokens": return .payloadOutputTokens
            case "reasoning_output_tokens": return .payloadReasoningOutputTokens
            case "total_tokens": return .payloadTotalTokens
            default: return nil
            }
        case .ignored: return nil
        }
    }
    private func childScope(_ scope: Scope, _ key: String?) -> Scope {
        switch (scope, key) {
        case (.root, "message"): .message
        case (.root, "payload"): .payload
        case (.message, "usage"): .messageUsage
        case (.payload, "usage"): .payloadUsage
        default: .ignored
        }
    }

    private mutating func finish(_ number: NumberToken) {
        guard number.accepting else { fail(.malformed); return }
        token = nil
        if let field = number.field {
            guard number.integerOnly, let value = Int(number.text), value >= 0, !number.text.hasPrefix("-") else {
                fail(.invalidSelectedField); return
            }
            fields[field] = .integer(value)
        }
    }
    private mutating func consumeNumber(_ byte: UInt8, _ number: inout NumberToken) {
        let digit = (48...57).contains(byte)
        switch number.phase {
        case .sign:
            guard digit else { fail(.malformed); return }
            number.phase = byte == 48 ? .zero : .integer
        case .zero, .integer:
            if digit, number.phase == .integer { break }
            if byte == 46 { number.phase = .dot; number.integerOnly = false }
            else if byte == 101 || byte == 69 { number.phase = .exponent; number.integerOnly = false }
            else { fail(.malformed); return }
        case .dot:
            guard digit else { fail(.malformed); return }
            number.phase = .fraction
        case .fraction:
            if digit { break }
            guard byte == 101 || byte == 69 else { fail(.malformed); return }
            number.phase = .exponent; number.integerOnly = false
        case .exponent:
            if byte == 43 || byte == 45 { number.phase = .exponentSign }
            else if digit { number.phase = .exponentDigits }
            else { fail(.malformed); return }
        case .exponentSign:
            guard digit else { fail(.malformed); return }
            number.phase = .exponentDigits
        case .exponentDigits:
            guard digit else { fail(.malformed); return }
        }
        if number.field != nil {
            guard number.text.utf8.count < 20 else { fail(.invalidSelectedField); return }
            number.text.unicodeScalars.append(UnicodeScalar(byte))
        }
    }
    private mutating func finish(_ literal: LiteralToken) {
        token = nil
        if let field = literal.field { fields[field] = .null }
    }

    private mutating func append(_ scalar: UInt32, to string: inout StringToken) {
        guard let unicode = UnicodeScalar(scalar) else { fail(.malformed); return }
        guard string.isKey || string.field != nil else { return }
        let size = scalar < 0x80 ? 1 : scalar < 0x800 ? 2 : scalar < 0x10000 ? 3 : 4
        if string.isKey {
            guard !string.keyTooLong else { return }
            guard string.length + size <= 32 else {
                string.keyTooLong = true; string.text = ""; return
            }
        } else if string.length + size > 4096 { fail(.invalidSelectedField); return }
        string.length += size
        string.text.unicodeScalars.append(unicode)
    }

    private mutating func consumeString(_ byte: UInt8, _ string: inout StringToken) {
        if string.utfRemaining > 0 {
            guard (0x80...0xBF).contains(byte) else { fail(.malformed); return }
            string.utfValue = (string.utfValue << 6) | UInt32(byte & 0x3F)
            string.utfRemaining -= 1
            if string.utfRemaining == 0 {
                guard string.utfValue >= string.utfMinimum, string.utfValue <= 0x10FFFF,
                      !(0xD800...0xDFFF).contains(string.utfValue) else { fail(.malformed); return }
                append(string.utfValue, to: &string)
            }
        } else {
            switch string.mode {
            case .normal:
                if byte == 34 { finish(string); return }
                if byte == 92 { string.mode = .escape }
                else if byte < 32 { fail(.malformed); return }
                else if byte < 0x80 { append(UInt32(byte), to: &string) }
                else if (0xC2...0xDF).contains(byte) {
                    string.utfRemaining = 1; string.utfValue = UInt32(byte & 0x1F); string.utfMinimum = 0x80
                } else if (0xE0...0xEF).contains(byte) {
                    string.utfRemaining = 2; string.utfValue = UInt32(byte & 0x0F); string.utfMinimum = 0x800
                } else if (0xF0...0xF4).contains(byte) {
                    string.utfRemaining = 3; string.utfValue = UInt32(byte & 0x07); string.utfMinimum = 0x10000
                } else { fail(.malformed); return }
            case .escape:
                string.mode = .normal
                switch byte {
                case 34, 92, 47: append(UInt32(byte), to: &string)
                case 98: append(8, to: &string)
                case 102: append(12, to: &string)
                case 110: append(10, to: &string)
                case 114: append(13, to: &string)
                case 116: append(9, to: &string)
                case 117: string.mode = .hex; string.hexCount = 0; string.hexValue = 0
                default: fail(.malformed); return
                }
            case .surrogateSlash:
                guard byte == 92 else { fail(.malformed); return }
                string.mode = .surrogateU
            case .surrogateU:
                guard byte == 117 else { fail(.malformed); return }
                string.mode = .hex; string.hexCount = 0; string.hexValue = 0
            case .hex:
                let value: UInt32
                switch byte {
                case 48...57: value = UInt32(byte - 48)
                case 65...70: value = UInt32(byte - 65 + 10)
                case 97...102: value = UInt32(byte - 97 + 10)
                default: fail(.malformed); return
                }
                string.hexValue = (string.hexValue << 4) | value
                string.hexCount += 1
                if string.hexCount == 4 {
                    let value = string.hexValue
                    if let high = string.highSurrogate {
                        guard (0xDC00...0xDFFF).contains(value) else { fail(.malformed); return }
                        append(0x10000 + ((high - 0xD800) << 10) + value - 0xDC00, to: &string)
                        string.highSurrogate = nil; string.mode = .normal
                    } else if (0xD800...0xDBFF).contains(value) {
                        string.highSurrogate = value; string.mode = .surrogateSlash
                    } else if (0xDC00...0xDFFF).contains(value) { fail(.malformed); return }
                    else { append(value, to: &string); string.mode = .normal }
                }
            }
        }
        if warning == nil { token = .string(string) }
    }
    private mutating func finish(_ string: StringToken) {
        token = nil
        if string.isKey {
            let index = frames.count - 1
            let key = string.keyTooLong ? nil : string.text
            if let key, selectedField(frames[index].scope, key) != nil || childScope(frames[index].scope, key) != .ignored {
                guard frames[index].seen.insert(key).inserted else { fail(.invalidSelectedField); return }
                frames[index].key = key
            } else { frames[index].key = nil }
            frames[index].phase = .colon
        } else if let field = string.field { fields[field] = .string(string.text) }
    }
}
