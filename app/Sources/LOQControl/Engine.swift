import Foundation
import IOKit
import CSensors
import LOQCore

// MARK: - Hardware monitor (reads the LOQFanMon kext, AppleSMC and the NVIDIA RM interface)

final class HardwareMonitor {
    private let queue = DispatchQueue(label: "com.local.loq.monitor", qos: .utility)

    func sample(completion: @escaping (HardwareSnapshot) -> Void) {
        queue.async {
            let ecData = self.readECData()
            let cpuT = self.readCPUTemp(ecTemp: ecData?.ecCPUTemp)
            let (gpuT, nvrmOk) = self.readGPUTemp()

            let snapshot = HardwareSnapshot(
                timestamp: Date(),
                cpuRPM: ecData?.cpu,
                gpuRPM: ecData?.gpu,
                cpuTemp: cpuT,
                gpuTemp: gpuT,
                ecCPUTemp: ecData?.ecCPUTemp,
                performanceMode: ecData?.mode,
                isMaxFan: ecData?.isMaxFan,
                kextConnected: ecData != nil,
                nvrmConnected: nvrmOk
            )
            DispatchQueue.main.async { completion(snapshot) }
        }
    }

    private func readECData() -> (cpu: Int, gpu: Int, mode: PerformanceMode?, ecCPUTemp: Int?, isMaxFan: Bool?)? {
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("LOQFanMon"), &it) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(it) }

        let svc = IOIteratorNext(it)
        guard svc != 0 else { return nil }
        defer { IOObjectRelease(svc) }

        func byte(_ key: String) -> Int? {
            guard let prop = IORegistryEntryCreateCFProperty(svc, key as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? NSNumber else { return nil }
            return prop.intValue
        }

        guard let rawCPU = byte("FA1S"), let rawGPU = byte("FA2S") else { return nil }
        guard let cpuRPM = HardwareDecoder.rawByteToRPM(rawCPU),
              let gpuRPM = HardwareDecoder.rawByteToRPM(rawGPU) else { return nil }

        let mode = byte("PMOD").flatMap { HardwareDecoder.decodePerformanceMode($0) }
        let ecTemp = byte("CTMP")
        let isMax = byte("FFON").map { HardwareDecoder.decodeMaxFan($0) }
        return (cpuRPM, gpuRPM, mode, ecTemp, isMax)
    }

    private func readCPUTemp(ecTemp: Int?) -> Double? {
        var temp: Double = 0
        if omen_smc_read("TC0P", &temp) == 0 && HardwareDecoder.isValidTemperature(temp) { return temp }
        if omen_smc_read("TC0D", &temp) == 0 && HardwareDecoder.isValidTemperature(temp) { return temp }
        if let ecT = ecTemp, ecT > 0 && ecT <= 125 { return Double(ecT) }
        return nil
    }

    private func readGPUTemp() -> (Double?, Bool) {
        var temp: Double = 0
        var msg = [CChar](repeating: 0, count: 256)
        let ret = omen_nvidia_temperature(&temp, &msg, msg.count)
        if ret == 0 && HardwareDecoder.isValidTemperature(temp) { return (temp, true) }
        return (nil, ret != -1)
    }
}

// MARK: - Fan ramping / curve engine (slew-limited, with fail-safes)

final class FanRampingManager {
    var config: FanCurveConfig = FanCurveConfig.load()
    private(set) var activeMode: FanControlMode = .auto
    private(set) var commandedRPM: Double = 0
    private(set) var filteredTemp: Double?

    private var target: Double = 0
    private var lastTick = Date()
    private var releasingToAuto = false
    private var fullFanSet = false

    func setMode(_ mode: FanControlMode, currentRPM: Int) {
        let wasManual = (activeMode != .auto)
        activeMode = mode
        filteredTemp = nil
        releasingToAuto = false
        fullFanSet = false
        lastTick = Date()
        commandedRPM = Double(min(max(currentRPM, config.minRPM), config.maxRPM))
        switch mode {
        case .auto:
            if wasManual {
                releasingToAuto = true
                target = min(commandedRPM, 2400)
            } else {
                restoreAutoNow()
            }
        case .maxSpeed:
            // Do not set the firmware Full Fan bit yet: it jumps straight to full speed.
            _ = HardwareDecoder.setMaxFan(false)
            target = Double(config.maxRPM)
        case .fixed(let rpm):
            target = Double(min(max(rpm, config.minRPM), config.maxRPM))
        case .customCurve:
            target = commandedRPM
        }
    }

    func setFixedTarget(_ rpm: Int) {
        guard case .fixed = activeMode else { return }
        let clamped = min(max(rpm, config.minRPM), config.maxRPM)
        activeMode = .fixed(rpm: clamped)
        target = Double(clamped)
    }

    /// Called about once per second. Sends one slew-limited command per call, which also
    /// serves as the heartbeat for the kext watchdog.
    func tick(cpuTemp: Double?, gpuTemp: Double?, actualRPM: Int?) {
        let now = Date()
        let dt = min(max(now.timeIntervalSince(lastTick), 0.1), 3.0)
        lastTick = now
        var up = config.upRate

        switch activeMode {
        case .auto:
            guard releasingToAuto else { return }
            if step(up: up, dt: dt) { restoreAutoNow() }

        case .maxSpeed:
            if step(up: up, dt: dt), !fullFanSet {
                fullFanSet = true
                _ = HardwareDecoder.setMaxFan(true)   // only once we are already at max
            }

        case .fixed:
            _ = step(up: up, dt: dt)

        case .customCurve:
            // FAIL-SAFE: no valid CPU temperature -> hand control back to the firmware.
            guard let cpu = cpuTemp, HardwareDecoder.isValidTemperature(cpu) else {
                restoreAutoNow()
                return
            }
            var hottest = cpu
            if let g = gpuTemp, HardwareDecoder.isValidTemperature(g) { hottest = max(hottest, g) }

            filteredTemp = filteredTemp.map { $0 + config.tempSmoothing * (hottest - $0) } ?? hottest
            var t = Double(HardwareDecoder.evaluateFanCurve(config.points, forTemp: filteredTemp ?? hottest))

            // Emergency override uses the RAW temperature so cooling is never delayed.
            if hottest >= config.emergencyTemp {
                t = Double(config.maxRPM)
                up = config.emergencyUpRate
            }
            target = min(max(t, Double(config.minRPM)), Double(config.maxRPM))
            _ = step(up: up, dt: dt)
        }
    }

    @discardableResult
    private func step(up: Double, dt: Double) -> Bool {
        let delta = target - commandedRPM
        if delta > 0 { commandedRPM += min(delta, up * dt) }
        else         { commandedRPM += max(delta, -config.downRate * dt) }
        commandedRPM = min(max(commandedRPM, Double(config.minRPM)), Double(config.maxRPM))
        let rounded = Int((commandedRPM / 100.0).rounded()) * 100
        _ = HardwareDecoder.setFanSpeed(rpm: rounded)
        return abs(target - commandedRPM) < 1.0
    }

    /// Hand fan control back to the firmware (Auto, quit, sleep and fail-safe).
    func restoreAutoNow() {
        _ = HardwareDecoder.setFanSpeed(rpm: 0)
        _ = HardwareDecoder.setMaxFan(false)
        activeMode = .auto
        releasingToAuto = false
        fullFanSet = false
        filteredTemp = nil
    }
}

// MARK: - Observable model for the UI

enum UIMode: String, CaseIterable, Identifiable {
    case auto, curve, fixed, max
    var id: String { rawValue }
    var title: String {
        switch self {
        case .auto:  return "Firmware Auto"
        case .curve: return "Custom Curve"
        case .fixed: return "Fixed Speed"
        case .max:   return "Max Fan"
        }
    }
}

enum CurvePreset: String, CaseIterable, Identifiable {
    case quiet = "Quiet", balanced = "Balanced", aggressive = "Aggressive"
    var id: String { rawValue }
    var points: [FanCurvePoint] {
        switch self {
        case .quiet:
            return [(50, 1900), (60, 2200), (70, 2600), (80, 3200), (88, 4000), (92, 5000)]
                .map { FanCurvePoint(temp: Double($0.0), rpm: $0.1) }
        case .balanced:
            return HardwareDecoder.defaultFanCurve
        case .aggressive:
            return [(40, 2200), (50, 2800), (60, 3400), (70, 4000), (80, 4600), (85, 5000)]
                .map { FanCurvePoint(temp: Double($0.0), rpm: $0.1) }
        }
    }
}

final class ControlModel: ObservableObject {
    static let shared = ControlModel()

    @Published var snapshot: HardwareSnapshot?
    @Published var activeMode: FanControlMode = .auto
    @Published var applied: FanCurveConfig
    @Published var draft: FanCurveConfig
    @Published var fixedRPM: Double = 3000
    @Published var commandedRPM: Int = 0
    @Published var filteredTemp: Double?
    @Published var message: String?

    static let tempMin = 30.0
    static let tempMax = 100.0
    static let maxPoints = 12

    private let monitor = HardwareMonitor()
    private let manager = FanRampingManager()
    private var timer: Timer?

    init() {
        let c = FanCurveConfig.load()
        applied = c
        draft = c
        manager.config = c
        // Always start in firmware Auto. Manual control is never resumed automatically.
        manager.restoreAutoNow()
        refresh()
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(t, forMode: .common)   // .common so it keeps running while menus are open
        timer = t
    }

    // MARK: derived values

    var uiMode: UIMode {
        switch activeMode {
        case .auto: return .auto
        case .customCurve: return .curve
        case .fixed: return .fixed
        case .maxSpeed: return .max
        }
    }

    var currentTemp: Double? {
        let temps = [snapshot?.cpuTemp, snapshot?.gpuTemp].compactMap { $0 }.filter { HardwareDecoder.isValidTemperature($0) }
        return temps.max()
    }

    var menuTitle: String {
        guard let s = snapshot else { return "Fan …" }
        return HardwareDecoder.formatMenuTitle(cpuTemp: s.cpuTemp, cpuRPM: s.cpuRPM,
                                               gpuTemp: s.gpuTemp, gpuRPM: s.gpuRPM,
                                               isMaxFan: activeMode == .maxSpeed)
    }

    /// Compact form for the menu bar next to the fan icon, e.g. "52° · 2000".
    var compactMenuTitle: String {
        guard let s = snapshot else { return "Fan" }
        var parts: [String] = []
        if let t = s.cpuTemp, HardwareDecoder.isValidTemperature(t) { parts.append("\(Int(round(t)))°") }
        if let r = s.cpuRPM { parts.append("\(r)") }
        return parts.isEmpty ? "Fan" : parts.joined(separator: " · ")
    }

    var isDirty: Bool { draft != applied }

    // MARK: sampling

    private func refresh() {
        monitor.sample { [weak self] s in
            guard let self = self else { return }
            self.snapshot = s
            self.manager.tick(cpuTemp: s.cpuTemp, gpuTemp: s.gpuTemp, actualRPM: s.cpuRPM)
            self.activeMode = self.manager.activeMode
            self.commandedRPM = Int(self.manager.commandedRPM.rounded())
            self.filteredTemp = self.manager.filteredTemp
        }
    }

    // MARK: mode control

    func select(_ mode: UIMode) {
        let current = snapshot?.cpuRPM ?? 2000
        switch mode {
        case .auto:  manager.setMode(.auto, currentRPM: current)
        case .curve: manager.setMode(.customCurve, currentRPM: current)
        case .fixed: manager.setMode(.fixed(rpm: Int(fixedRPM)), currentRPM: current)
        case .max:   manager.setMode(.maxSpeed, currentRPM: current)
        }
        activeMode = manager.activeMode
    }

    func fixedChanged(_ value: Double) {
        manager.setFixedTarget(Int(value))
        activeMode = manager.activeMode
    }

    func restoreAuto() {
        manager.restoreAutoNow()
        activeMode = manager.activeMode
    }

    // MARK: curve editing (works on the draft; nothing is sent to hardware until Apply)

    func movePoint(_ i: Int, temp: Double, rpm: Int) {
        var pts = draft.points
        guard pts.indices.contains(i) else { return }
        let lo = i > 0 ? pts[i - 1].temp + 1 : Self.tempMin
        let hi = i < pts.count - 1 ? pts[i + 1].temp - 1 : Self.tempMax
        let t = min(max(temp.rounded(), lo), hi)
        let rlo = i > 0 ? pts[i - 1].rpm : draft.minRPM
        let rhi = i < pts.count - 1 ? pts[i + 1].rpm : draft.maxRPM
        let snapped = Int((Double(rpm) / 100.0).rounded()) * 100
        let r = min(max(snapped, rlo), rhi)
        pts[i] = FanCurvePoint(temp: t, rpm: r)
        draft.points = pts
    }

    /// Inserts a point on the current curve at `temp`. Returns its index, or nil if not possible.
    @discardableResult
    func addPoint(temp: Double) -> Int? {
        guard draft.points.count < Self.maxPoints else {
            message = "Maximum of \(Self.maxPoints) points."
            return nil
        }
        let t = min(max(temp.rounded(), Self.tempMin), Self.tempMax)
        guard !draft.points.contains(where: { abs($0.temp - t) < 3 }) else { return nil }
        let r = HardwareDecoder.evaluateFanCurve(draft.points, forTemp: t)
        var pts = draft.points
        pts.append(FanCurvePoint(temp: t, rpm: r))
        pts.sort { $0.temp < $1.temp }
        draft.points = pts
        return pts.firstIndex(where: { $0.temp == t })
    }

    /// Adds a point in the middle of the widest temperature gap (used by the "Add point" button).
    func addPointInLargestGap() {
        let pts = draft.points
        guard pts.count >= 2 else { return }
        var bestGap = 0.0
        var mid = 0.0
        for k in 0..<(pts.count - 1) {
            let gap = pts[k + 1].temp - pts[k].temp
            if gap > bestGap { bestGap = gap; mid = pts[k].temp + gap / 2 }
        }
        if bestGap < 6 { message = "No room to add a point; move or delete one first."; return }
        addPoint(temp: mid)
    }

    func removePoint(_ i: Int) {
        guard draft.points.count > 2, draft.points.indices.contains(i) else { return }
        draft.points.remove(at: i)
    }

    func loadPreset(_ p: CurvePreset) {
        var c = draft
        c.points = p.points
        draft = c
    }

    func revertDraft() { draft = applied; message = nil }

    func resetToDefaults() { draft = FanCurveConfig.defaults; message = nil }

    func applyDraft() {
        guard let ok = draft.validated() else {
            message = "Curve rejected: it needs at least 2 points, speeds must not drop as temperature rises, and values must be within safe limits."
            return
        }
        ok.save()
        applied = ok
        draft = ok
        manager.config = ok
        message = "Curve applied and saved."
    }
}
