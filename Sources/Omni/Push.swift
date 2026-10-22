import Foundation
#if canImport(UserNotifications)
import UserNotifications
#endif

/// The pieces of push the SDK reports (PROTOCOL.md, Push notifications): the APNs token, the permission, and opens
/// of Omni's own pushes. Omni sends the pushes itself, from the founder's Mac.
enum Push {
    /// `$push_token` goes out again after this long even when nothing changed, so Omni knows the device is still there.
    static let resendAfter: TimeInterval = 7 * 24 * 60 * 60

    /// The APNs device token as lowercase hex (what APNs expects in the request path).
    static func hex(_ token: Data) -> String {
        token.map { String(format: "%02x", $0) }.joined()
    }

    /// `sandbox` or `production`: which APNs servers this build's tokens belong to. Read from the provisioning
    /// profile Xcode embeds (`aps-environment`); App Store and TestFlight builds have none and are production.
    static func environment(bundle: Bundle = .main) -> String {
        #if targetEnvironment(simulator)
        return "sandbox"
        #else
        return environment(profile: provisioningProfile(bundle: bundle))
        #endif
    }

    static func environment(profile: Data?) -> String {
        guard let profile, let plist = profilePlist(profile),
              let entitlements = plist["Entitlements"] as? [String: Any] else { return "production" }
        let aps = (entitlements["aps-environment"] ?? entitlements["com.apple.developer.aps-environment"]) as? String
        return aps == "development" ? "sandbox" : "production"
    }

    /// `embedded.mobileprovision` (iOS, tvOS) or `Contents/embedded.provisionprofile` (macOS).
    static func provisioningProfile(bundle: Bundle) -> Data? {
        let candidates = [
            bundle.url(forResource: "embedded", withExtension: "mobileprovision"),
            bundle.bundleURL.appendingPathComponent("Contents/embedded.provisionprofile"),
        ]
        return candidates.lazy.compactMap { $0.flatMap { try? Data(contentsOf: $0) } }.first
    }

    /// A provisioning profile is a signed (CMS) envelope around an XML plist: the plist is cut out as is.
    static func profilePlist(_ profile: Data) -> [String: Any]? {
        guard let start = profile.range(of: Data("<?xml".utf8)),
              let end = profile.range(of: Data("</plist>".utf8), in: start.lowerBound..<profile.endIndex) else { return nil }
        let xml = profile.subdata(in: start.lowerBound..<end.upperBound)
        return (try? PropertyListSerialization.propertyList(from: xml, format: nil)) as? [String: Any]
    }

    /// Omni's part of a push payload: `"omni": { "message_id": "m_…", "url": "…" }` next to `aps`.
    /// Nil when the push isn't Omni's.
    static func omniMessage(_ userInfo: [AnyHashable: Any]) -> (messageId: String, url: URL?)? {
        guard let omni = userInfo["omni"] as? [AnyHashable: Any], let id = omni["message_id"] as? String, !id.isEmpty else { return nil }
        let url = (omni["url"] as? String).flatMap { $0.isEmpty ? nil : URL(string: $0) }
        return (id, url)
    }
}

/// Reads the notification permission and calls back with its `$push_permission` status (or nil when it can't tell).
/// Injected, because `UNUserNotificationCenter` crashes outside an app bundle (unit tests).
typealias PushPermissionReader = (_ completion: @escaping (String?) -> Void) -> Void

enum SystemPushPermission {
    /// The system reader, or nil where there's none to ask (app extensions, command-line tools, watchOS).
    static func reader() -> PushPermissionReader? {
        #if canImport(UserNotifications) && !os(watchOS)
        guard Bundle.main.bundleURL.pathExtension == "app" else { return nil }
        return { completion in
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                completion(status(settings.authorizationStatus))
            }
        }
        #else
        return nil
        #endif
    }

    #if canImport(UserNotifications) && !os(watchOS)
    static func status(_ s: UNAuthorizationStatus) -> String? {
        switch s {
        case .authorized: return "authorized"
        case .denied: return "denied"
        case .notDetermined: return "not_determined"
        case .provisional: return "provisional"
        #if os(iOS)
        case .ephemeral: return "ephemeral"
        #endif
        @unknown default: return nil
        }
    }
    #endif
}
