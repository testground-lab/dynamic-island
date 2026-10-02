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
    }
}

/// Horizontal "remaining" bar with label, percentage and reset time.
struct QuotaBar: View {
    var window: QuotaWindow
    var tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(window.label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.secondary)
                Spacer(minLength: 4)
                Text("\(Format.percent(window.remainingFraction)) left")
                    .font(Theme.number(11))
                    .foregroundStyle(window.tint(base: .white))
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.track)
                    Capsule()
                        .fill(window.tint(base: tint))
                        .frame(width: geo.size.width * (window.remainingFraction ?? 0))
                }
            }
            .frame(height: 4)
            if let reset = Format.reset(window.resetsAt) {
                Text("resets \(reset)")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.tertiary)
            }
        }
        .animation(Theme.spring, value: window.usedFraction)
    }
}

struct HealthBadge: View {
    var health: AccountHealth

    var body: some View {
        if let (text, color) = describe() {
            Text(text)
                .font(.system(size: 9.5, weight: .semibold))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .foregroundStyle(color)
                .background(color.opacity(0.16), in: Capsule())
                .lineLimit(1)
        }
    }

    private func describe() -> (String, Color)? {
        switch health {
        case .ok:
            return nil
        case .disabled:
            return ("Disabled", Theme.tertiary)
        case .error(let message):
            return (message.isEmpty ? "Error" : String(message.prefix(28)), Theme.danger)
        case .rateLimited(let until, _):
            if let reset = Format.reset(until) { return ("Limited · \(reset)", Theme.warning) }
            return ("Rate limited", Theme.warning)
        }
    }
}

struct ProviderGlyph: View {
    var provider: Provider
    var size: CGFloat = 18

    var body: some View {
        Image(systemName: provider.symbol)
            .font(.system(size: size * 0.5, weight: .bold))
            .foregroundStyle(provider.tint)
            .frame(width: size, height: size)
            .background(provider.tint.opacity(0.18), in: RoundedRectangle(cornerRadius: size * 0.3, style: .continuous))
    }
}

struct ConnectionDot: View {
    var state: ConnectionState

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 6, height: 6)
            .shadow(color: color.opacity(0.8), radius: 3)
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
