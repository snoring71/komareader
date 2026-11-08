import Foundation

/// A stable, anonymous id for this device, used as the key for per-device reading progress.
public enum DeviceIdentity {
    private static let key = "ComicReader.deviceId"

    public static func current(defaults: UserDefaults = .standard, platformPrefix: String = "apple") -> String {
        if let existing = defaults.string(forKey: key) { return existing }
        let id = "\(platformPrefix)-\(UUID().uuidString.prefix(8).lowercased())"
        defaults.set(id, forKey: key)
        return id
    }
}
