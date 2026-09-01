import Foundation
import OSLog

enum LegacyDefaults {
    private static let flagKey = "didMigrateDefaultsFromEdgeMark"
    private static let oldBundleID = "io.github.ender-wang.EdgeMark" as CFString

    /// Copy UserDefaults from the previous EdgeMark bundle ID. Idempotent.
    static func importIfNeeded() {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: flagKey) == nil else { return }
        defaults.set(true, forKey: flagKey)

        guard let keys = CFPreferencesCopyKeyList(
            oldBundleID,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost,
        ) as? [String], !keys.isEmpty else { return }

        for key in keys {
            if defaults.object(forKey: key) != nil { continue }
            if let value = CFPreferencesCopyAppValue(key as CFString, oldBundleID) {
                defaults.set(value, forKey: key)
            }
        }
        Log.app.info("[Migration] imported UserDefaults from EdgeMark")
    }
}
