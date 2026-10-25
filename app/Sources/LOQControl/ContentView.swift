import SwiftUI
import LOQCore

struct ContentView: View {
    @EnvironmentObject var model: ControlModel

    var body: some View {
        VStack(spacing: 14) {
            HeaderBar()

            HStack(spacing: 14) {
                FanGaugeCard(kind: .cpu)
                FanGaugeCard(kind: .gpu)
                ControlCard()
            }
            .frame(height: 198)

            HStack(alignment: .top, spacing: 14) {
                EditorCard()
                VStack(spacing: 14) {
                    PointsCard()
                    SettingsCard()
                }
                .frame(width: 308)
            }
            .frame(maxHeight: .infinity)
        }
        .padding(16)
    }
}

// MARK: - Header

private struct AppIconView: View {
    var body: some View {
        if let icon = NSImage(named: "AppIcon") {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: 44, height: 44)
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(LinearGradient(colors: [.blue, .cyan],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                Image(systemName: "fanblades.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(.white)
            }
            .frame(width: 44, height: 44)
        }
    }
}

struct HeaderBar: View {
    @EnvironmentObject var model: ControlModel

    var body: some View {
        HStack(spacing: 12) {
            AppIconView()
            VStack(alignment: .leading, spacing: 1) {
                Text("LOQ Fan Control").font(.title3.bold())
                Text("Lenovo LOQ 15IAX9 · embedded controller")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer(minLength: 12)

            Picker("Mode", selection: Binding(get: { model.uiMode }, set: { model.select($0) })) {
                ForEach(UIMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 372)

            KextPill()
        }
    }
}

// MARK: - Fan gauge cards

enum FanKind {
    case cpu, gpu
    var title: String { self == .cpu ? "CPU fan" : "GPU fan" }
    var icon: String { self == .cpu ? "cpu.fill" : "fanblades.fill" }
    var tempLabel: String { self == .cpu ? "CPU" : "GPU" }
}

struct FanGaugeCard: View {
    @EnvironmentObject var model: ControlModel
    let kind: FanKind

    private var rpm: Int? { kind == .cpu ? model.snapshot?.cpuRPM : model.snapshot?.gpuRPM }
    private var temperature: Double? { kind == .cpu ? model.snapshot?.cpuTemp : model.snapshot?.gpuTemp }

    private var fraction: Double {
        guard let rpm = rpm else { return 0 }
        return min(max(Double(rpm) / 5000.0, 0), 1)
    }

    /// Only shown on the GPU card when the dGPU is asleep; the row is reserved in both
    /// cards so the RPM numbers sit at exactly the same height.
    private var noteText: String? {
        guard kind == .gpu, temperature == nil,
              model.snapshot?.nvrmConnected == false else { return nil }
        return "dGPU asleep — temp unavailable"
    }

    var body: some View {
        HStack(spacing: 16) {
            ZStack {
                ArcGauge(value: fraction, color: Theme.tempColor(temperature))
                    .frame(width: 106, height: 106)
                VStack(spacing: 0) {
                    Group {
                        if let t = temperature {
                            Text("\(Int(round(t)))°")
                                .font(.system(size: 24, weight: .bold, design: .rounded))
                                .monospacedDigit()
                                .foregroundColor(Theme.tempColor(t))
                        } else {
                            Image(systemName: "thermometer.medium")
                                .font(.system(size: 20))
                                .foregroundColor(.secondary)
                        }
                    }
                    .frame(height: 30)
                    Text(kind.tempLabel)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            .frame(width: 106, height: 106)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: kind.icon)
                        .imageScale(.small)
                        .foregroundColor(.secondary)
                    Text(kind.title)
                        .font(.subheadline.weight(.semibold))
                }
                .frame(height: 18)
                Text(rpm.map { "\($0)" } ?? "n/a")
                    .font(.system(size: 34, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                    .frame(height: 40)
                Text("RPM")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(noteText ?? " ")
                    .font(.caption2)
                    .foregroundColor(.orange)
                    .lineLimit(1)
                    .frame(height: 14, alignment: .top)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .cardStyle()
    }
}

// MARK: - Control card

struct ControlCard: View {
    @EnvironmentObject var model: ControlModel

    private var modeBadge: (String, Color) {
        switch model.uiMode {
        case .auto:  return ("Firmware Auto", .green)
        case .curve: return ("Custom Curve", .blue)
        case .fixed: return ("Fixed Speed", .orange)
        case .max:   return ("Max Fan", .red)
        }
    }

    private var powerChip: (String, Color)? {
        guard let m = model.snapshot?.performanceMode else { return nil }
        switch m {
        case .quiet:        return ("Quiet", .blue)
        case .balanced:     return ("Balanced", .secondary)
        case .performance:  return ("Performance", .red)
        case .custom:       return ("Custom", .purple)
        case .extreme:      return ("Extreme", .orange)
        }
    }

    private var emergencyActive: Bool {
        model.activeMode == .customCurve && (model.currentTemp ?? 0) >= model.applied.emergencyTemp
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                CardHeader(title: "Control", systemImage: "gearshape.fill")
                Spacer()
                Chip(text: modeBadge.0, color: modeBadge.1)
            }

            row("Fan target", model.activeMode == .auto ? "Firmware" : "\(model.commandedRPM) RPM")
            row("Power mode", powerChip.map { $0.0 } ?? "n/a")
            row("Full-fan flag", model.snapshot?.isMaxFan == true ? "Active" : "Off")

            if model.uiMode == .fixed {
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("Fixed speed").foregroundColor(.secondary)
                        Spacer()
                        Text("\(Int(model.fixedRPM)) RPM").monospacedDigit()
                    }
                    Slider(value: $model.fixedRPM, in: 1900...5000, step: 100)
                        .onChange(of: model.fixedRPM) { model.fixedChanged($0) }
                }
            }

            if emergencyActive {
                HStack(spacing: 6) {
                    Image(systemName: "flame.fill")
                    Text("EMERGENCY — fans forced to max")
                }
                .font(.caption.weight(.semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.red))
            }

            Spacer(minLength: 0)

            HStack {
                KextPill()
                Spacer()
                Text("Auto-restored on quit · sleep · sensor loss")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .cardStyle()
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).foregroundColor(.secondary)
            Spacer()
            Text(value).monospacedDigit()
        }
    }
}

// MARK: - Curve editor card

struct EditorCard: View {
    @EnvironmentObject var model: ControlModel

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                CardHeader(title: "Fan curve", systemImage: "chart.xyaxis.line")
                if model.isDirty { Chip(text: "unsaved", color: .orange) }
                Spacer()
                Text("Drag points · click the line or double-click to add")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            CurveEditorView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack {
                Menu {
                    ForEach(CurvePreset.allCases) { p in
                        Button(p.rawValue) { model.loadPreset(p) }
                    }
                } label: {
                    Label("Presets", systemImage: "slider.horizontal.3")
                }
                .fixedSize()

                Button { model.resetToDefaults() } label: {
                    Label("Reset", systemImage: "arrow.counterclockwise")
                }
                Button { model.revertDraft() } label: {
                    Label("Revert", systemImage: "arrow.uturn.backward")
                }
                .disabled(!model.isDirty)

                Spacer()

                if let msg = model.message {
                    Text(msg)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
                Button { model.applyDraft() } label: {
                    Label("Apply & Save", systemImage: "checkmark.circle.fill")
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.isDirty)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .cardStyle()
    }
}

// MARK: - Points table

struct PointsCard: View {
    @EnvironmentObject var model: ControlModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                CardHeader(title: "Points", systemImage: "list.bullet")
                Spacer()
                Text("\(model.draft.points.count)/\(ControlModel.maxPoints)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            ScrollView {
                VStack(spacing: 2) {
                    ForEach(Array(model.draft.points.enumerated()), id: \.offset) { entry in
                        let i = entry.offset
                        HStack(spacing: 6) {
                            Text("\(i + 1)")
                                .font(.caption2.weight(.semibold))
                                .monospacedDigit()
                                .frame(width: 20, height: 20)
                                .background(Circle().fill(Color.primary.opacity(0.08)))
                                .foregroundColor(.secondary)
                            TextField("°C", value: Binding(
                                get: { model.draft.points.indices.contains(i) ? model.draft.points[i].temp : 0 },
                                set: { newT in
                                    guard model.draft.points.indices.contains(i) else { return }
                                    model.movePoint(i, temp: newT, rpm: model.draft.points[i].rpm)
                                }),
                                format: .number.precision(.fractionLength(0)))
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 52)
                            Text("°C").foregroundColor(.secondary).font(.caption)
                            TextField("RPM", value: Binding(
                                get: { model.draft.points.indices.contains(i) ? model.draft.points[i].rpm : 0 },
                                set: { newR in
                                    guard model.draft.points.indices.contains(i) else { return }
                                    model.movePoint(i, temp: model.draft.points[i].temp, rpm: newR)
                                }),
                                format: .number.precision(.fractionLength(0)))
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 64)
                            Text("RPM").foregroundColor(.secondary).font(.caption)
                            Spacer(minLength: 0)
                            Button {
                                model.removePoint(i)
                            } label: {
                                Image(systemName: "minus.circle")
                                    .foregroundColor(.red)
                            }
                            .buttonStyle(.borderless)
                            .disabled(model.draft.points.count <= 2)
                        }
                    }
                }
            }
            .frame(maxHeight: .infinity)

            Button {
                model.addPointInLargestGap()
            } label: {
                Label("Add point in widest gap", systemImage: "plus")
            }
            .disabled(model.draft.points.count >= ControlModel.maxPoints)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .cardStyle()
    }
}

// MARK: - Ramp / safety settings

struct SettingsCard: View {
    @EnvironmentObject var model: ControlModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CardHeader(title: "Ramping & safety", systemImage: "thermometer.high")

            slider("Speed-up rate", icon: "wind", value: $model.draft.upRate,
                   range: 20...300, step: 10, unit: "RPM/s")
            slider("Slow-down rate", icon: "snowflake", value: $model.draft.downRate,
                   range: 10...150, step: 5, unit: "RPM/s")
            slider("Temp smoothing", icon: "water.waves", value: $model.draft.tempSmoothing,
                   range: 0.05...1.0, step: 0.05, unit: "")
            slider("Emergency temp", icon: "flame", value: $model.draft.emergencyTemp,
                   range: 75...100, step: 1, unit: "°C")

            Text("At or above the emergency temperature the fans go to maximum quickly, ignoring the slow ramp.")
                .font(.caption2)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    private func slider(_ title: String, icon: String, value: Binding<Double>,
                        range: ClosedRange<Double>, step: Double, unit: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .imageScale(.small)
                    .foregroundColor(.secondary)
                Text(title)
                Spacer()
                Text(String(format: step < 1 ? "%.2f" : "%.0f", value.wrappedValue) + (unit.isEmpty ? "" : " \(unit)"))
                    .monospacedDigit()
                    .foregroundColor(.secondary)
            }
            Slider(value: value, in: range, step: step)
        }
    }
}
