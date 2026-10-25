import Foundation
import IOKit

public enum PerformanceMode: Int, CustomStringConvertible, Equatable {
    case balanced = 0
    case performance = 1
    case quiet = 2
    case custom = 3
    case extreme = 7

    public var description: String {
        switch self {
        case .balanced: return "Balanced (White)"
        case .performance: return "Performance (Red)"
        case .quiet: return "Quiet (Blue)"
        case .custom: return "Custom"
        case .extreme: return "Extreme"
        }
    }
}

public enum FanControlMode: Equatable {
    case auto
    case maxSpeed
    case fixed(rpm: Int)
    case customCurve
}

public struct FanCurvePoint: Equatable, Codable {
    public let temp: Double
    public let rpm: Int

    public init(temp: Double, rpm: Int) {
        self.temp = temp
        self.rpm = rpm
    }
}

public struct HardwareSnapshot: Equatable {
    public let timestamp: Date
    public let cpuRPM: Int?
    public let gpuRPM: Int?
    public let cpuTemp: Double?
    public let gpuTemp: Double?
    public let ecCPUTemp: Int?
    public let performanceMode: PerformanceMode?
    public let isMaxFan: Bool?
    public let kextConnected: Bool
    public let nvrmConnected: Bool

    public init(
        timestamp: Date = Date(),
        cpuRPM: Int?,
        gpuRPM: Int?,
        cpuTemp: Double?,
        gpuTemp: Double?,
        ecCPUTemp: Int? = nil,
        performanceMode: PerformanceMode? = nil,
        isMaxFan: Bool? = nil,
        kextConnected: Bool,
        nvrmConnected: Bool
    ) {
        self.timestamp = timestamp
        self.cpuRPM = cpuRPM
        self.gpuRPM = gpuRPM
        self.cpuTemp = cpuTemp
        self.gpuTemp = gpuTemp
        self.ecCPUTemp = ecCPUTemp
        self.performanceMode = performanceMode
        self.isMaxFan = isMaxFan
        self.kextConnected = kextConnected
        self.nvrmConnected = nvrmConnected
    }
}

public enum HardwareDecoder {
    /// Lenovo LOQ OEM firmware fan conversion: RPM = raw byte * 100 (0x64)
    /// Valid raw fan range: 0 to 80 (0 to 8000 RPM)
    public static func rawByteToRPM(_ raw: Int) -> Int? {
        guard raw >= 0 && raw <= 80 else { return nil }
        return raw * 100
    }

    /// Lenovo LOQ GZ44 Performance Mode decoder (ECMM offset 0x00B, bits 5..7):
    /// 0 = Balanced (White LED)
    /// 1 = Performance (Red LED)
    /// 2 = Quiet (Blue LED)
    /// 3 = Custom
    /// 7 = Extreme
    public static func decodePerformanceMode(_ raw: Int) -> PerformanceMode? {
        return PerformanceMode(rawValue: raw)
    }

    /// Full Fan (Max Speed) decoder from EFAN offset 0x0B6 (bit 0):
    /// 1 = Full Fan Active (Max Speed)
    /// 0 = Normal / Firmware Auto
    public static func decodeMaxFan(_ raw: Int) -> Bool {
        return (raw & 0x01) == 1
    }

    /// Verifies if measured temperature is within reasonable laptop operating limits
    public static func isValidTemperature(_ temp: Double) -> Bool {
        return temp.isFinite && temp > 0 && temp <= 125
    }

    /// Calculates smooth, gradual acceleration/deceleration between current RPM and target RPM.
    /// Prevents abrupt motor shock and harsh acoustic jumps.
    public static func nextRampRPM(current: Int, target: Int, maxStep: Int = 300) -> Int {
        if abs(target - current) <= maxStep {
            return target
        }
        return target > current ? current + maxStep : current - maxStep
    }

    /// Default 6-point smooth gaming fan curve:
    /// Below 45°C: 1800 RPM (Quiet)
    /// 55°C: 2400 RPM
    /// 65°C: 3000 RPM
    /// 75°C: 3600 RPM
    /// 85°C: 4400 RPM
    /// 90°C+: 5000 RPM (Max)
    public static let defaultFanCurve: [FanCurvePoint] = [
        FanCurvePoint(temp: 45.0, rpm: 1800),
        FanCurvePoint(temp: 55.0, rpm: 2400),
        FanCurvePoint(temp: 65.0, rpm: 3000),
        FanCurvePoint(temp: 75.0, rpm: 3600),
        FanCurvePoint(temp: 85.0, rpm: 4400),
        FanCurvePoint(temp: 90.0, rpm: 5000)
    ]

    /// Evaluates target RPM from a list of curve points with linear interpolation.
    public static func evaluateFanCurve(_ points: [FanCurvePoint], forTemp temp: Double) -> Int {
        guard !points.isEmpty else { return 2500 }
        let sorted = points.sorted { $0.temp < $1.temp }

        if temp <= sorted.first!.temp {
            return sorted.first!.rpm
        }
        if temp >= sorted.last!.temp {
            return sorted.last!.rpm
        }

        for i in 0..<(sorted.count - 1) {
            let p1 = sorted[i]
            let p2 = sorted[i + 1]
            if temp >= p1.temp && temp <= p2.temp {
                let factor = (temp - p1.temp) / (p2.temp - p1.temp)
                let delta = Double(p2.rpm - p1.rpm)
                return p1.rpm + Int(round(factor * delta))
            }
        }
        return sorted.last!.rpm
    }

    /// Compact format for macOS menu-bar title
    public static func formatMenuTitle(cpuTemp: Double?, cpuRPM: Int?, gpuTemp: Double?, gpuRPM: Int?, isMaxFan: Bool? = nil) -> String {
        let cpuStr: String
        if let t = cpuTemp, let rpm = cpuRPM {
            cpuStr = "CPU \(Int(round(t)))°·\(rpm)"
        } else if let rpm = cpuRPM {
            cpuStr = "CPU \(rpm)"
        } else if let t = cpuTemp {
            cpuStr = "CPU \(Int(round(t)))°"
        } else {
            cpuStr = "CPU n/a"
        }

        let gpuStr: String
        if let t = gpuTemp, let rpm = gpuRPM {
            gpuStr = "GPU \(Int(round(t)))°·\(rpm)"
        } else if let rpm = gpuRPM {
            gpuStr = "GPU \(rpm)"
        } else if let t = gpuTemp {
            gpuStr = "GPU \(Int(round(t)))°"
        } else {
            gpuStr = "GPU n/a"
        }

        let baseTitle = "\(cpuStr) | \(gpuStr)"
        if isMaxFan == true {
            return "\(baseTitle) [MAX]"
        }
        return baseTitle
    }

    /// Dispatches SetFanRPM to both CPU and GPU fans via LOQFanMon kext EC Command (0x46 / 0x85 & 0x86)
    /// Pass rpm = 0 to restore automatic firmware fan curve.
    public static func setFanSpeed(rpm: Int) -> Bool {
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("LOQFanMon"), &it) == KERN_SUCCESS else {
            return false
        }
        defer { IOObjectRelease(it) }

        let svc = IOIteratorNext(it)
        guard svc != 0 else { return false }
        defer { IOObjectRelease(svc) }

        let num = NSNumber(value: rpm)
        let retCPU = IORegistryEntrySetCFProperty(svc, "SetCPUFanRPM" as CFString, num)
        let retGPU = IORegistryEntrySetCFProperty(svc, "SetGPUFanRPM" as CFString, num)
        return retCPU == KERN_SUCCESS && retGPU == KERN_SUCCESS
    }

    /// Dispatches SetMaxFan (Full Fan) call through LOQFanMon kext
    public static func setMaxFan(_ enabled: Bool) -> Bool {
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("LOQFanMon"), &it) == KERN_SUCCESS else {
            return false
        }
        defer { IOObjectRelease(it) }

        let svc = IOIteratorNext(it)
        guard svc != 0 else { return false }
        defer { IOObjectRelease(svc) }

        let num = NSNumber(value: enabled ? 1 : 0)
        let ret = IORegistryEntrySetCFProperty(svc, "SetMaxFan" as CFString, num)
        return ret == KERN_SUCCESS
    }
}


// MARK: - Editable fan curve + gradual-ramp settings (stored as JSON)

public struct FanCurveConfig: Codable, Equatable {
    public var points: [FanCurvePoint]
    public var minRPM: Int
    public var maxRPM: Int
    /// Maximum acceleration while speeding up, in RPM per second.
    public var upRate: Double
    /// Maximum deceleration while slowing down, in RPM per second.
    public var downRate: Double
    /// At or above this temperature (C) the fans go to maxRPM and the slow ramp is bypassed.
    public var emergencyTemp: Double
    public var emergencyUpRate: Double
    /// 0.05...1.0. Lower = smoother temperature input (less fan hunting).
    public var tempSmoothing: Double

    public init(points: [FanCurvePoint], minRPM: Int, maxRPM: Int, upRate: Double, downRate: Double,
                emergencyTemp: Double, emergencyUpRate: Double, tempSmoothing: Double) {
        self.points = points; self.minRPM = minRPM; self.maxRPM = maxRPM
        self.upRate = upRate; self.downRate = downRate
        self.emergencyTemp = emergencyTemp; self.emergencyUpRate = emergencyUpRate
        self.tempSmoothing = tempSmoothing
    }

    public static let defaults = FanCurveConfig(
        points: HardwareDecoder.defaultFanCurve,
        minRPM: 1900, maxRPM: 5000,
        upRate: 100, downRate: 40,
        emergencyTemp: 90, emergencyUpRate: 500,
        tempSmoothing: 0.25)

    /// Returns a sanitized copy, or nil if the file contains unsafe or nonsensical values.
    public func validated() -> FanCurveConfig? {
        guard points.count >= 2, minRPM >= 1000, maxRPM <= 6500, minRPM < maxRPM,
              upRate > 0, downRate > 0, emergencyUpRate > 0,
              (0.05...1.0).contains(tempSmoothing), (70.0...100.0).contains(emergencyTemp),
              points.allSatisfy({ $0.temp >= 20 && $0.temp <= 110 }) else { return nil }
        var c = self
        c.points = points
            .map { FanCurvePoint(temp: $0.temp, rpm: min(max($0.rpm, minRPM), maxRPM)) }
            .sorted { $0.temp < $1.temp }
        // A curve that gets SLOWER as it gets hotter is never valid.
        guard zip(c.points, c.points.dropFirst()).allSatisfy({ $1.rpm >= $0.rpm }) else { return nil }
        return c
    }

    public static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("FanBar/curve.json")
    }

    /// Loads ~/Library/Application Support/FanBar/curve.json; falls back to defaults if missing/invalid.
    public static func load() -> FanCurveConfig {
        if let data = try? Data(contentsOf: fileURL),
           let cfg = try? JSONDecoder().decode(FanCurveConfig.self, from: data),
           let ok = cfg.validated() { return ok }
        if !FileManager.default.fileExists(atPath: fileURL.path) { defaults.save() }
        return defaults
    }

    public func save() {
        try? FileManager.default.createDirectory(at: Self.fileURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(self) { try? data.write(to: Self.fileURL) }
    }
}
