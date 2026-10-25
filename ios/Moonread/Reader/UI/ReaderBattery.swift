import SwiftUI
import UIKit

/// Battery monitoring is a platform concern and only runs while reading.
@MainActor @Observable
final class ReaderBattery {
    private(set) var level: Float = -1
    private(set) var state: UIDevice.BatteryState = .unknown
    private var observers: [NSObjectProtocol] = []
    private var wasMonitoring = false

    var symbol: String? { Self.symbol(level: level, state: state) }

    static func symbol(level: Float, state: UIDevice.BatteryState) -> String? {
        guard level >= 0 else { return nil }
        if state == .charging { return "battery.100percent.bolt" }
        switch level {
        case ..<0.125: return "battery.0percent"
        case ..<0.375: return "battery.25percent"
        case ..<0.625: return "battery.50percent"
        case ..<0.875: return "battery.75percent"
        default: return "battery.100percent"
        }
    }

    var accessibilityLabel: String {
        guard level >= 0 else { return String(localized: "电量不可用") }
        let percentage = Int((level * 100).rounded())
        return state == .charging ? String(localized: "电量百分之\(percentage)，正在充电") : String(localized: "电量百分之\(percentage)")
    }

    func start() {
        guard observers.isEmpty else { return }
        wasMonitoring = UIDevice.current.isBatteryMonitoringEnabled
        UIDevice.current.isBatteryMonitoringEnabled = true
        refresh()
        observers = [UIDevice.batteryLevelDidChangeNotification, UIDevice.batteryStateDidChangeNotification].map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.refresh() }
            }
        }
    }

    func refresh() {
        level = UIDevice.current.batteryLevel
        state = UIDevice.current.batteryState
    }

    func stop() {
        guard !observers.isEmpty else { return }
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        UIDevice.current.isBatteryMonitoringEnabled = wasMonitoring
    }
}
