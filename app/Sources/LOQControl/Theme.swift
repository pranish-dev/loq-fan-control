import SwiftUI

// MARK: - Shared look & feel for the dashboard

enum Theme {
    /// Color for a temperature reading, from cool to critical.
    static func tempColor(_ t: Double?) -> Color {
        guard let t = t else { return .secondary }
        switch t {
        case ..<50: return .blue
        case ..<65: return .teal
        case ..<75: return .green
        case ..<82: return .yellow
        case ..<90: return .orange
        default:    return .red
        }
    }
}

extension View {
    /// Rounded "dashboard card" background used across the window.
    func cardStyle() -> some View {
        self
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.regularMaterial))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
    }
}

/// Card section header: icon + title, matching across all cards.
struct CardHeader: View {
    let title: String
    let systemImage: String

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.headline)
            .foregroundColor(.primary)
    }
}

/// Small colored capsule tag (mode, dirty state, ...).
struct Chip: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .foregroundColor(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.16)))
    }
}

/// Circular progress ring showing an RPM value as a fraction of the maximum.
struct ArcGauge: View {
    let value: Double   // 0...1
    let color: Color
    var lineWidth: CGFloat = 9

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.08), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: CGFloat(min(max(value, 0), 1)))
                .stroke(
                    AngularGradient(colors: [color.opacity(0.55), color], center: .center,
                                    startAngle: .degrees(-90), endAngle: .degrees(270)),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.6), value: value)
        }
    }
}

/// Green/red connection indicator with label.
struct KextPill: View {
    @EnvironmentObject var model: ControlModel

    private var connected: Bool { model.snapshot?.kextConnected ?? false }

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(connected ? Color.green : Color.red)
                .frame(width: 8, height: 8)
            Text(connected ? "Kext" : "No kext")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(Color.primary.opacity(0.06)))
        .help(connected ? "LOQFanMon kext connected" : "LOQFanMon kext not found")
    }
}
