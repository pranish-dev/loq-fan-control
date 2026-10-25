import Foundation
import LOQCore

func check(_ desc: String, _ condition: Bool) {
    if condition {
        print("[PASS] \(desc)")
    } else {
        print("[FAIL] \(desc)")
        exit(1)
    }
}

print("=== Running LOQCore Validation Checks ===")

// 1. RPM conversion confirmed by firmware
check("19 raw byte converts to 1900 RPM", HardwareDecoder.rawByteToRPM(19) == 1900)
check("22 raw byte converts to 2200 RPM", HardwareDecoder.rawByteToRPM(22) == 2200)
check("26 raw byte converts to 2600 RPM", HardwareDecoder.rawByteToRPM(26) == 2600)
check("0 raw byte converts to 0 RPM", HardwareDecoder.rawByteToRPM(0) == 0)

// 2. Out of range rejection
check("Negative fan byte rejected", HardwareDecoder.rawByteToRPM(-1) == nil)
check("Extreme fan byte (>80) rejected", HardwareDecoder.rawByteToRPM(85) == nil)

// 3. Performance mode decoding (GZ44 hardware LED calibrated)
check("0 decodes to Balanced (White)", HardwareDecoder.decodePerformanceMode(0) == .balanced)
check("1 decodes to Performance (Red)", HardwareDecoder.decodePerformanceMode(1) == .performance)
check("2 decodes to Quiet (Blue)", HardwareDecoder.decodePerformanceMode(2) == .quiet)
check("3 decodes to Custom", HardwareDecoder.decodePerformanceMode(3) == .custom)
check("7 decodes to Extreme", HardwareDecoder.decodePerformanceMode(7) == .extreme)
check("Invalid mode value returns nil", HardwareDecoder.decodePerformanceMode(4) == nil)

// 4. Max Fan (FFON) decoding
check("FFON 1 decodes to active", HardwareDecoder.decodeMaxFan(1) == true)
check("FFON 0 decodes to inactive", HardwareDecoder.decodeMaxFan(0) == false)
check("FFON masked with bit 0 (0x03 decodes to active)", HardwareDecoder.decodeMaxFan(3) == true)

// 5. Gradual Slew-Rate Ramping checks
check("Ramp up step by +300", HardwareDecoder.nextRampRPM(current: 2600, target: 5000, maxStep: 300) == 2900)
check("Ramp up near target finishes at target", HardwareDecoder.nextRampRPM(current: 4900, target: 5000, maxStep: 300) == 5000)
check("Ramp down step by -300", HardwareDecoder.nextRampRPM(current: 5000, target: 2600, maxStep: 300) == 4700)
check("Ramp down near target finishes at target", HardwareDecoder.nextRampRPM(current: 2800, target: 2600, maxStep: 300) == 2600)

// 6. Custom Fan Curve interpolation checks
let curve = HardwareDecoder.defaultFanCurve
check("Curve below minimum clamps to 1800", HardwareDecoder.evaluateFanCurve(curve, forTemp: 35.0) == 1800)
check("Curve above maximum clamps to 5000", HardwareDecoder.evaluateFanCurve(curve, forTemp: 98.0) == 5000)
check("Curve at exact point 55°C is 2400", HardwareDecoder.evaluateFanCurve(curve, forTemp: 55.0) == 2400)
check("Curve halfway between 55°C (2400) and 65°C (3000) interpolates to 2700", HardwareDecoder.evaluateFanCurve(curve, forTemp: 60.0) == 2700)

// 7. Temperature validation
check("Normal CPU temp (45.0) is valid", HardwareDecoder.isValidTemperature(45.0))
check("High CPU temp (95.5) is valid", HardwareDecoder.isValidTemperature(95.5))
check("Sub-zero temp (-5.0) is rejected", !HardwareDecoder.isValidTemperature(-5.0))
check("Zero temp (0.0) is rejected", !HardwareDecoder.isValidTemperature(0.0))
check("Excessive temp (130.0) is rejected", !HardwareDecoder.isValidTemperature(130.0))
check("NaN temp is rejected", !HardwareDecoder.isValidTemperature(Double.nan))

// 8. Menu bar string formatting
let full = HardwareDecoder.formatMenuTitle(cpuTemp: 46.2, cpuRPM: 1900, gpuTemp: 43.1, gpuRPM: 2200)
check("Full reading format", full == "CPU 46°·1900 | GPU 43°·2200")

let fullMax = HardwareDecoder.formatMenuTitle(cpuTemp: 46.2, cpuRPM: 4800, gpuTemp: 43.1, gpuRPM: 4900, isMaxFan: true)
check("Full reading with MAX tag format", fullMax == "CPU 46°·4800 | GPU 43°·4900 [MAX]")

print("All 27 validation checks passed successfully!")
