import Foundation
import Network
import Observation
import UIKit

/// Decides when the cover job may fetch books from iCloud: never on Low Data Mode, Low Power
/// Mode or a low battery, and only on Wi-Fi if the user asks. Books already on the device (or
/// with a synced cover) are never held back.
@MainActor
@Observable
final class CoverPolicy {
    var makeCoversForCloudBooks: Bool {
        didSet { UserDefaults.standard.set(makeCoversForCloudBooks, forKey: Keys.enabled); update() }
    }
    var wifiOnly: Bool {
        didSet { UserDefaults.standard.set(wifiOnly, forKey: Keys.wifiOnly); update() }
    }
    /// Why books in iCloud are waiting for their covers, or nil when they are not.
    private(set) var pauseReason: String?
    var allowsCloudDownloads: Bool { pauseReason == nil }

    /// Called with the new value whenever `allowsCloudDownloads` changes.
    @ObservationIgnored var onChange: ((Bool) -> Void)?

    private enum Keys {
        static let enabled = "covers.makeForCloudBooks"
        static let wifiOnly = "covers.wifiOnly"
    }

    @ObservationIgnored private let monitor = NWPathMonitor()
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    private var isConnected = true
    private var isOnWiFi = true
    private var isConstrained = false

    init() {
        let defaults = UserDefaults.standard
        defaults.register(defaults: [Keys.enabled: true, Keys.wifiOnly: true])
        makeCoversForCloudBooks = defaults.bool(forKey: Keys.enabled)
        wifiOnly = defaults.bool(forKey: Keys.wifiOnly)

        UIDevice.current.isBatteryMonitoringEnabled = true
        let center = NotificationCenter.default
        for name in [UIDevice.batteryLevelDidChangeNotification, UIDevice.batteryStateDidChangeNotification,
                     Notification.Name.NSProcessInfoPowerStateDidChange] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.update() }
            })
        }
        monitor.pathUpdateHandler = { [weak self] path in
            let connected = path.status == .satisfied
            let wifi = path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet)
            let constrained = path.isConstrained
            Task { @MainActor in
                self?.isConnected = connected
                self?.isOnWiFi = wifi
                self?.isConstrained = constrained
                self?.update()
            }
        }
        monitor.start(queue: DispatchQueue(label: "CoverPolicy.network", qos: .utility))
        update()
    }

    private func update() {
        let wasAllowed = allowsCloudDownloads
        pauseReason = currentReason()
        if wasAllowed != allowsCloudDownloads { onChange?(allowsCloudDownloads) }
    }

    private func currentReason() -> String? {
        if !makeCoversForCloudBooks { return "Turned off" }
        if !isConnected { return "Waiting for a network connection" }
        if isConstrained { return "Paused while Low Data Mode is on" }
        if wifiOnly && !isOnWiFi { return "Waiting for Wi-Fi" }
        if ProcessInfo.processInfo.isLowPowerModeEnabled { return "Paused while Low Power Mode is on" }
        let device = UIDevice.current
        // The level is -1 when unknown (for example in the simulator).
        if device.batteryState == .unplugged, device.batteryLevel >= 0, device.batteryLevel < 0.2 {
            return "Paused while the battery is low"
        }
        return nil
    }
}
