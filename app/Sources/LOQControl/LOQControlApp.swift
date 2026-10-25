import SwiftUI
import AppKit
import LOQCore

@main
struct LOQControlApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = ControlModel.shared

    var body: some Scene {
        Window("LOQ Fan Control", id: "main") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 960, minHeight: 660)
        }
        .windowResizability(.contentMinSize)

        MenuBarExtra {
            MenuContent()
                .environmentObject(model)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "fanblades.fill")
                Text(model.compactMenuTitle)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hand fans back to the firmware before the Mac sleeps.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
                ControlModel.shared.restoreAuto()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        ControlModel.shared.restoreAuto()
    }

    // Closing the window must NOT stop fan control; the menu bar item keeps the app alive.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

struct MenuContent: View {
    @EnvironmentObject var model: ControlModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if let s = model.snapshot {
            Section("Live") {
                Text(menuRow("CPU", s.cpuTemp, s.cpuRPM))
                Text(menuRow("GPU", s.gpuTemp, s.gpuRPM))
            }
        }
        Section("Fan mode") {
            ForEach(UIMode.allCases) { mode in
                Button((model.uiMode == mode ? "✓ " : "") + mode.title) { model.select(mode) }
            }
        }
        if model.uiMode != .auto {
            Button("Restore Firmware Auto now") { model.restoreAuto() }
            Divider()
        }
        Button("Open LOQ Fan Control") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Divider()
        Button("Quit (restores firmware fan control)") { NSApplication.shared.terminate(nil) }
    }

    private func menuRow(_ name: String, _ t: Double?, _ rpm: Int?) -> String {
        var parts = [name]
        if let t = t, HardwareDecoder.isValidTemperature(t) {
            parts.append("\(Int(round(t)))°C")
        } else {
            parts.append("n/a")
        }
        if let rpm = rpm { parts.append("\(rpm) RPM") }
        return parts.joined(separator: "  ·  ")
    }
}
