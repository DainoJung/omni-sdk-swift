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

    /// Whether this platform can show Omni's buttons (notification categories): sent as `buttons` with `$push_token`.
    static let showsButtons: Bool = {
        #if canImport(UserNotifications) && !os(watchOS) && !os(tvOS)
        return true
        #else
        return false
        #endif
    }()

    #if canImport(UserNotifications) && !os(watchOS) && !os(tvOS)
    /// What opening one of Omni's pushes means: the `$push_opened` action (`open`, or the button's id) and the URL to
    /// open. Nil when the push isn't Omni's or was dismissed (not an open). A button's url comes from its category in
    /// the config, else the push's own; a button that leaves the app in the background and has no url opens nothing.
    static func opened(actionIdentifier: String, categoryIdentifier: String, userInfo: [AnyHashable: Any],
                       categories: [PushCategory]) -> (messageId: String, action: String, url: URL?)? {
        guard actionIdentifier != UNNotificationDismissActionIdentifier,
              let message = omniMessage(userInfo) else { return nil }
        if actionIdentifier == UNNotificationDefaultActionIdentifier {
            return (message.messageId, "open", message.url)
        }
        let button = categories.first { $0.id == categoryIdentifier }?.actions.first { $0.id == actionIdentifier }
        if let button, !button.foreground, button.url == nil {
            return (message.messageId, actionIdentifier, nil)
        }
        return (message.messageId, actionIdentifier, button?.url ?? message.url)
    }
    #endif
}

/// A set of buttons Omni's pushes can carry (PROTOCOL.md, Push buttons): registered with the system as a notification
/// category, and named by the push's `aps.category`. Only ids starting with `omni_`, so the app's own are never touched.
struct PushCategory: Decodable, Equatable {
    static let prefix = "omni_"

    var id: String
    var actions: [PushAction]

    init(id: String, actions: [PushAction]) {
        self.id = id
        self.actions = actions
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        guard id.hasPrefix(PushCategory.prefix), id.count > PushCategory.prefix.count else {
            throw DecodingError.dataCorruptedError(forKey: .id, in: c, debugDescription: "not an omni_ category")
        }
        // A button in a shape this version can't read is left out, not the whole category.
        actions = try c.decode([Lossy<PushAction>].self, forKey: .actions).compactMap(\.value)
    }

    enum CodingKeys: String, CodingKey { case id, actions }
}

struct PushAction: Decodable, Equatable {
    var id: String
    var title: String
    var url: URL?
    /// Tapping it brings the app to the foreground.
    var foreground: Bool

    init(id: String, title: String, url: URL? = nil, foreground: Bool) {
        self.id = id
        self.title = title
        self.url = url
        self.foreground = foreground
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        guard !id.isEmpty, !title.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .id, in: c, debugDescription: "empty id or title")
        }
        url = ((try? c.decodeIfPresent(String.self, forKey: .url)) ?? nil).flatMap { $0.isEmpty ? nil : URL(string: $0) }
        // Absent: a button with a link has to open the app to follow it.
        foreground = ((try? c.decodeIfPresent(Bool.self, forKey: .foreground)) ?? nil) ?? (url != nil)
    }

    enum CodingKeys: String, CodingKey { case id, title, url, foreground }
}

/// Hands Omni's push categories (all of them, from the config just loaded) to the system, next to the app's own.
/// Injected, like the permission reader: `UNUserNotificationCenter` crashes outside an app bundle.
typealias PushCategoryRegistrar = (_ categories: [PushCategory]) -> Void

enum SystemPushCategories {
    /// The system registrar, or nil where there's nothing to register with (app extensions, tools, tvOS, watchOS).
    static func registrar() -> PushCategoryRegistrar? {
        #if canImport(UserNotifications) && !os(watchOS) && !os(tvOS)
        guard Bundle.main.bundleURL.pathExtension == "app" else { return nil }
        return { categories in
            let center = UNUserNotificationCenter.current()
            register(categories,
                     get: { done in center.getNotificationCategories { done($0) } },
                     set: { center.setNotificationCategories($0) })
        }
        #else
        return nil
        #endif
    }

    #if canImport(UserNotifications) && !os(watchOS) && !os(tvOS)
    /// Reads the current categories, swaps the `omni_` ones for `categories` and sets the union, keeping the app's own.
    /// Skipped when Omni's are already exactly these, so loading the same config again changes nothing; comparing with
    /// what the system holds (not what was last set) puts Omni's back if the app replaced the whole set meanwhile.
    static func register(_ categories: [PushCategory],
                         get: (@escaping (Set<UNNotificationCategory>) -> Void) -> Void,
                         set: @escaping (Set<UNNotificationCategory>) -> Void) {
        get { current in
            let isOmni = { (c: UNNotificationCategory) in c.identifier.hasPrefix(PushCategory.prefix) }
            let registered = Set(current.filter(isOmni).map(Signature.init))
            guard registered != Set(categories.map(Signature.init)) else { return }
            set(current.filter { !isOmni($0) }.union(categories.map(category)))
        }
    }

    static func category(_ c: PushCategory) -> UNNotificationCategory {
        let actions = c.actions.map {
            UNNotificationAction(identifier: $0.id, title: $0.title, options: $0.foreground ? [.foreground] : [])
        }
        return UNNotificationCategory(identifier: c.id, actions: actions, intentIdentifiers: [], options: [])
    }

    /// What the system shows of a category: a url change alone needs no re-registration (it's read at open time).
    private struct Signature: Hashable {
        struct Button: Hashable { var id: String; var title: String; var foreground: Bool }
        var id: String
        var buttons: [Button]

        init(_ c: PushCategory) {
            id = c.id
            buttons = c.actions.map { Button(id: $0.id, title: $0.title, foreground: $0.foreground) }
        }

        init(_ c: UNNotificationCategory) {
            id = c.identifier
            buttons = c.actions.map { Button(id: $0.identifier, title: $0.title, foreground: $0.options.contains(.foreground)) }
        }
    }
    #endif
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
