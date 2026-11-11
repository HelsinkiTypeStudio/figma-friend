import Foundation
import Security

enum Settings {
    static let port: UInt16 = 7337
    static let version = "1.0.0"

    private static let defaults = UserDefaults.standard

    /// The key a plugin must send in the X-Helper-Key header. Made once, kept until reset.
    static var pairingKey: String {
        if let k = defaults.string(forKey: "pairingKey"), !k.isEmpty { return k }
        return resetPairingKey()
    }

    @discardableResult
    static func resetPairingKey() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let k = bytes.map { String(format: "%02x", $0) }.joined()
        defaults.set(k, forKey: "pairingKey")
        return k
    }

    static var lastSaveFolder: URL? {
        get { defaults.string(forKey: "lastSaveFolder").map { URL(fileURLWithPath: $0) } }
        set { defaults.set(newValue?.path, forKey: "lastSaveFolder") }
    }
}
