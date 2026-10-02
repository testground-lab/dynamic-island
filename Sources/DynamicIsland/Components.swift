import IslandCore
import SwiftUI

/// Ring that drains as quota is used: the arc is what's *left*.
struct QuotaRing: View {
    var window: QuotaWindow?
    var tint: Color
    var lineWidth: CGFloat = 3

    var body: some View {
        let remaining = window?.remainingFraction ?? 0
        ZStack {
            Circle().stroke(Theme.track, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: remaining)
                .stroke(window?.tint(base: tint) ?? Theme.tertiary,
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .animation(Theme.spring, value: remaining)
        .accessibilityHidden(true)
    }
}

/// One limit window, dense: label, countdown to reset, % left, then a thin
/// meter with a tick for how much of the window has elapsed (being left of
/// the tick means quota is being used faster than time passes).
struct LimitRow: View {
    var window: QuotaWindow
    var tint: Color
    var now: Date

    var body: some View {
        let color = window.tint(base: tint)
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Text(window.label)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
                    .layoutPriority(1)
                if let reset = Format.countdown(window.resetsAt, now: now) {
                    HStack(spacing: 2) {
                        Image(systemName: "arrow.clockwise").font(.system(size: 7.5, weight: .semibold))
                        Text(reset)
                    }
                    .font(.system(size: 9.5))
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
                }
                Spacer(minLength: 2)
                Text(Format.percent(window.remainingFraction))
                    .font(Theme.number(12))
                    .foregroundStyle(color == tint ? Color.white : color)
                    .contentTransition(.numericText())
            }
            Meter(value: window.remainingFraction ?? 0,
                  tick: window.elapsedFraction(now: now).map { 1 - $0 },
                  tint: color)
        }
        .animation(Theme.spring, value: window.usedFraction)
        .help(help)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(window.label) quota")
        .accessibilityValue(help)
    }

    private var help: String {
        [Format.percent(window.remainingFraction) + " left",
         window.resetsAt.map { "resets " + $0.formatted(.dateTime.weekday(.abbreviated).hour().minute()) }]
            .compactMap { $0 }.joined(separator: ", ")
    }
}

/// 4 pt capsule meter with an optional pace tick.
struct Meter: View {
    var value: Double
    var tick: Double?
    var tint: Color
    var height: CGFloat = 4

    var body: some View {
        let fraction = value.isFinite ? min(1, max(0, value)) : 0
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.track)
                Capsule().fill(tint.opacity(0.92))
                    .frame(width: max(fraction > 0 ? height : 0, geo.size.width * fraction))
                if let tick, tick > 0.02, tick < 0.98 {
                    Capsule().fill(.white.opacity(0.8))
                        .frame(width: 1.5, height: height + 4)
                        .offset(x: geo.size.width * tick - 0.75)
                }
            }
            .frame(height: geo.size.height)
        }
        .frame(height: height + 4)
        .accessibilityHidden(true)
    }
}

/// Tiny tinted label, e.g. a plan name or "Limited 29m".
struct Chip: View {
    var text: String
    var tint: Color

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(tint)
            .lineLimit(1)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(tint.opacity(0.15), in: Capsule())
    }
}

extension AccountHealth {
    /// Chip for anything but `.ok`.
    var chip: (text: String, tint: Color)? {
        switch self {
        case .ok: nil
        case .disabled: ("Off", Theme.tertiary)
        case .error: ("Error", Theme.danger)
        case .rateLimited(let until, _): ("Limited" + (Format.countdown(until).map { " " + $0 } ?? ""), Theme.warning)
        }
    }
}

struct ProviderGlyph: View {
    var provider: Provider
    var size: CGFloat = 13

    var body: some View {
        Image(systemName: provider.symbol)
            .font(.system(size: size * 0.78, weight: .bold))
            .foregroundStyle(provider.tint)
            .frame(width: size + 4, height: size + 4)
            .accessibilityHidden(true)
    }
}

struct ConnectionDot: View {
    var state: ConnectionState

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 6, height: 6)
            .shadow(color: color.opacity(0.8), radius: 3)
            .accessibilityLabel(label)
    }

    private var label: String {
        switch state {
        case .connected: "Connected"
        case .connecting: "Connecting"
        case .needsKey: "Management key needed"
        case .keyRejected: "Key rejected"
        case .proxyDown: "Proxy down"
        case .failed: "Connection failed"
        }
    }

    private var color: Color {
        switch state {
        case .connected: Theme.healthy
        case .connecting: Theme.secondary
        case .needsKey, .keyRejected: Theme.warning
        case .proxyDown, .failed: Theme.danger
        }
    }
}

extension ConnectionState {
    /// Proxy unreachable or erroring, as opposed to a key problem the user must fix in Settings.
    var isTransient: Bool {
        switch self {
        case .proxyDown, .failed: true
        default: false
        }
    }

    /// nil when everything is fine.
    var problem: (title: String, detail: String)? {
        switch self {
        case .connected, .connecting:
            return nil
        case .needsKey:
            return ("Management key needed", "Paste the CLIProxyAPI management key in Settings. It's stored in your Keychain.")
        case .keyRejected:
            return ("Key rejected (401)", "The proxy refused the management key. Update it in Settings.")
        case .proxyDown(let detail):
            return ("Proxy down", detail.isEmpty ? "Nothing is answering at the configured address." : detail)
        case .failed(let detail):
            return ("Can't read the proxy", detail)
        }
    }
}
