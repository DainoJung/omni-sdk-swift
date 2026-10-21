import Foundation

/// Turns a view controller's type name (`String(reflecting: type(of: vc))`) into a screen name, or nil when it
/// isn't a screen worth recording (system and container controllers, or a name we can't make sense of).
///
/// - `Scribo.WordListViewController` → `WordList`
/// - `SwiftUI.UIHostingController<SwiftUI.ModifiedContent<Scribo.PaywallView, …>>` → `Paywall`
/// - `UINavigationController`, `SwiftUI.UIHostingController<SwiftUI.AnyView>` → nil
enum ScreenName {
    /// Modules whose types are never the app's own screens.
    static let systemModules: Set<String> = [
        "Swift", "SwiftUI", "SwiftUICore", "UIKit", "Foundation", "Combine", "Observation", "CoreData",
        "SafariServices", "MessageUI", "Photos", "PhotosUI", "StoreKit", "AVKit", "QuickLook", "ContactsUI",
        "EventKitUI", "GameKit", "PassKit", "MapKit", "WebKit", "AuthenticationServices", "LinkPresentation",
        "PencilKit", "VisionKit", "TipKit", "__C",
    ]

    /// Prefixes of Objective-C system classes (they reflect without a module).
    static let systemPrefixes = [
        "_", "UI", "PU", "PH", "SF", "MF", "SK", "AV", "QL", "CN", "EK", "GK", "PK", "VN",
    ]

    /// App-side subclasses of containers aren't screens either: what they show is.
    static let containerSuffixes = [
        "NavigationController", "TabBarController", "SplitViewController", "PageViewController",
    ]

    /// The type `.omniScreen(...)` adds around a view: such views are recorded under their own name, not automatically.
    static let namedByAppMarker = "Omni.OmniScreenModifier"

    static func from(typeName raw: String) -> String? {
        let name = clean(raw)
        guard !name.isEmpty else { return nil }

        let base: String
        let generics: String?
        if let open = name.firstIndex(of: "<") {
            base = String(name[..<open])
            generics = String(name[name.index(after: open)...])
        } else {
            base = name
            generics = nil
        }
        guard isQualifiedName(base) else { return nil }
        // Views that name themselves with `.omniScreen(...)` are recorded by it, not automatically.
        if generics?.contains(namedByAppMarker) == true { return nil }

        if isAppType(base) {
            let last = lastComponent(base)
            if containerSuffixes.contains(where: last.hasSuffix) { return nil }
            return strip(last, suffixes: ["HostingController", "ViewController", "Controller"])
        }

        // A system wrapper (UIHostingController, ModifiedContent, …): the app's own view inside it names the screen.
        guard let generics else { return nil }
        let candidates = generics
            .split(whereSeparator: { !isNameCharacter($0) })
            .map(String.init)
            .filter { $0.contains(".") && isQualifiedName($0) && isAppType($0) }
        guard let pick = candidates.first(where: { lastComponent($0).hasSuffix("View") }) ?? candidates.first else {
            return nil
        }
        return strip(lastComponent(pick), suffixes: ["View"])
    }

    // MARK: Helpers

    /// Drops what Swift adds for private and local types:
    /// `Scribo.(unknown context at $10a3c).Foo` → `Scribo.Foo`, `Scribo.(Foo in _3A9F…)` → `Scribo.Foo`.
    static func clean(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for (pattern, template) in cleanups {
            s = pattern.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
        }
        return s
    }

    private static let cleanups: [(NSRegularExpression, String)] = [
        (#"\(unknown context at [^()]*\)\."#, ""),
        (#"\(([A-Za-z_][A-Za-z0-9_]*) in [^()]*\)"#, "$1"),
    ].compactMap { pattern, template in
        (try? NSRegularExpression(pattern: pattern)).map { ($0, template) }
    }

    static func isNameCharacter(_ c: Character) -> Bool {
        c == "." || c == "_" || c.isLetter || c.isNumber
    }

    /// `Module.Type`, `Module.Outer.Inner` or a bare Objective-C class name.
    static func isQualifiedName(_ s: String) -> Bool {
        guard !s.isEmpty, s.allSatisfy(isNameCharacter) else { return false }
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        return parts.allSatisfy { part in
            guard let first = part.first else { return false }
            return first == "_" || first.isLetter
        }
    }

    static func lastComponent(_ s: String) -> String {
        s.split(separator: ".").last.map(String.init) ?? s
    }

    /// Defined by the app (or a third-party package), not by Apple.
    static func isAppType(_ qualified: String) -> Bool {
        let parts = qualified.split(separator: ".").map(String.init)
        guard let last = parts.last, !last.hasPrefix("_") else { return false }
        if parts.count == 1 {
            // Objective-C class: no module to go by.
            return !systemPrefixes.contains(where: last.hasPrefix)
        }
        let module = parts[0]
        return !module.hasPrefix("_") && !systemModules.contains(module)
    }

    /// Removes the first matching suffix, unless that would leave nothing (a class named just `ViewController`).
    static func strip(_ name: String, suffixes: [String]) -> String {
        for suffix in suffixes where name.hasSuffix(suffix) {
            return name == suffix ? name : String(name.dropLast(suffix.count))
        }
        return name
    }
}

/// Lets a screen through unless it's the same as the one just before it (a screen showing again after a sheet or
/// alert closes isn't a new visit).
struct ScreenDeduper {
    private(set) var last: String?

    /// True when `name` should be sent; remembers it either way.
    mutating func shouldSend(_ name: String) -> Bool {
        defer { last = name }
        return name != last
    }

    /// An explicit `Omni.screen(...)` is always sent, but still counts as the last screen.
    mutating func record(_ name: String) {
        last = name
    }
}
