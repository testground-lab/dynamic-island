import AppKit
import IslandCore
import SwiftUI

enum Theme {
    /// Outer height of the open dashboard (island and popover alike). Fixed:
    /// content scrolls inside it, it never grows.
    static let openHeight: CGFloat = 262
    /// With Reduce Motion on, every animation becomes a short cross-fade-like ease.
    private static func motion(_ animation: Animation) -> Animation {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? .easeInOut(duration: 0.15) : animation
    }

    static var spring: Animation { motion(.spring(response: 0.42, dampingFraction: 0.8)) }
    /// Opening overshoots a little; closing settles without bounce and faster.
    static var open: Animation { motion(.spring(duration: 0.42, bounce: 0.22)) }
    static var close: Animation { motion(.spring(duration: 0.28, bounce: 0)) }
    /// Sliding between the open island's pages.
    static var page: Animation { motion(.spring(duration: 0.35, bounce: 0)) }
    /// The hover "pulse" on the closed island.
    static var emphasis: Animation { motion(.spring(duration: 0.3, bounce: 0.2)) }
    static let card = Color.white.opacity(0.06)
    static let cardStroke = Color.white.opacity(0.08)
    static let secondary = Color.white.opacity(0.55)
    static let tertiary = Color.white.opacity(0.32)
    static let track = Color.white.opacity(0.12)
    static let warning = Color(red: 1.0, green: 0.72, blue: 0.25)
    static let danger = Color(red: 1.0, green: 0.36, blue: 0.33)
    static let healthy = Color(red: 0.36, green: 0.86, blue: 0.55)

    static func number(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .rounded).monospacedDigit()
    }
}

extension Provider {
    var tint: Color {
        if isUnknown { return Color(white: 0.6) }
        return switch self {
        case .claude: Color(red: 0.85, green: 0.47, blue: 0.34)
        case .codex: Color(red: 0.31, green: 0.78, blue: 0.64)
        case .gemini: Color(red: 0.42, green: 0.60, blue: 1.0)
        case .other(let raw): Self.otherPalette[Self.stableIndex(raw, count: Self.otherPalette.count)]
        }
    }

    /// Distinct colours for providers without their own, picked by name so
    /// each keeps its colour across launches (unlike Swift's seeded hashing).
    private static let otherPalette: [Color] = [
        Color(red: 0.70, green: 0.66, blue: 0.95), Color(red: 0.95, green: 0.78, blue: 0.35),
        Color(red: 0.93, green: 0.52, blue: 0.70), Color(red: 0.45, green: 0.80, blue: 0.88),
        Color(red: 0.62, green: 0.83, blue: 0.45),
    ]

    private static func stableIndex(_ text: String, count: Int) -> Int {
        Int(text.unicodeScalars.reduce(UInt32(0)) { $0 &* 31 &+ $1.value } % UInt32(count))
    }

    var symbol: String {
        if isUnknown { return "questionmark.circle" }
        return switch self {
        case .claude: "asterisk"
        case .codex: "chevron.left.forwardslash.chevron.right"
        case .gemini: "sparkle"
        case .other: "circle.hexagongrid"
        }
    }
}

extension QuotaWindow {
    /// Neutral tint until the window gets tight, then amber, then red.
    func tint(base: Color) -> Color {
        guard let used = usedFraction else { return Theme.tertiary }
        if used >= 0.95 { return Theme.danger }
        if used >= 0.8 { return Theme.warning }
        return base
    }
}

enum Format {
    static func tokens(_ value: Int) -> String {
        let v = Double(value)
        switch abs(v) {
        case 1_000_000_000...: return String(format: "%.1fB", v / 1_000_000_000)
        case 1_000_000...: return String(format: "%.1fM", v / 1_000_000)
        case 10_000...: return String(format: "%.0fk", v / 1_000)
        case 1_000...: return String(format: "%.1fk", v / 1_000)
        default: return "\(value)"
        }
    }

    static func percent(_ fraction: Double?) -> String {
        guard let fraction else { return "–" }
        return "\(Int((fraction * 100).rounded()))%"
    }

    /// "in 2h 14m", "in 38m", or "Fri 09:00" when more than a day away.
    static func reset(_ date: Date?, now: Date = .now) -> String? {
        guard let date else { return nil }
        let seconds = date.timeIntervalSince(now)
        if seconds <= 0 { return "now" }
        if seconds >= 24 * 3600 {
            return date.formatted(.dateTime.weekday(.abbreviated).hour(.twoDigits(amPM: .omitted)).minute())
        }
        let minutes = Int(seconds / 60)
        if minutes < 1 { return "in <1m" }
        if minutes < 60 { return "in \(minutes)m" }
        return "in \(minutes / 60)h \(minutes % 60)m"
    }

    /// Compact time to a date: "2d 4h", "1h 59m", "29m". Never seconds.
    static func countdown(_ date: Date?, now: Date = .now) -> String? {
        guard let date else { return nil }
        let minutes = max(1, Int((date.timeIntervalSince(now) / 60).rounded(.up)))
        if minutes >= 24 * 60 { return "\(minutes / 1440)d \(minutes % 1440 / 60)h" }
        if minutes >= 60 { return "\(minutes / 60)h \(minutes % 60)m" }
        return "\(minutes)m"
    }

    static func ago(_ date: Date?, now: Date = .now) -> String {
        guard let date else { return "never" }
        let seconds = Int(now.timeIntervalSince(date))
        if seconds < 5 { return "just now" }
        if seconds < 60 { return "\(seconds)s ago" }
        if seconds < 3600 { return "\(seconds / 60)m ago" }
        return "\(seconds / 3600)h ago"
    }
}
