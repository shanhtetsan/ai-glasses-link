import Foundation
import UIKit

/// A device id that stays the same for this app install: identifierForVendor, saved on first use.
/// The saved value wins afterwards, so a nil identifierForVendor (possible before first unlock)
/// can't make it change mid-install; in that case a random UUID is saved instead.
enum DeviceIdentity {
    static let defaultsKey = "phoneCapture.deviceID"

    @MainActor
    static var current: String {
        resolve(defaults: .standard, vendorID: UIDevice.current.identifierForVendor)
    }

    static func resolve(defaults: UserDefaults, vendorID: UUID?) -> String {
        if let stored = defaults.string(forKey: defaultsKey), !stored.isEmpty {
            return stored
        }
        let id = (vendorID ?? UUID()).uuidString
        defaults.set(id, forKey: defaultsKey)
        return id
    }

    /// /ws/camera_thermal?source=phone&device=<id>
    static func phoneSensorURL(base: URL, deviceID: String) -> URL? {
        BackendEndpoint.webSocketURL(
            base: base,
            path: "/ws/camera_thermal",
            queryItems: [
                URLQueryItem(name: "source", value: "phone"),
                URLQueryItem(name: "device", value: deviceID),
            ]
        )
    }
}
