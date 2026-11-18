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

    /// A friendly name for a device id, from its platform prefix ("ipad-1a2b3c4d" gives "iPad").
    public static func displayName(for deviceId: String) -> String {
        let prefix = deviceId.split(separator: "-").first.map { $0.lowercased() } ?? ""
        switch prefix {
        case "ipad": return "iPad"
        case "iphone": return "iPhone"
        case "mac": return "Mac"
        case "win", "windows": return "Windows"
        default: return "another device"
        }
    }
}
