#if canImport(SwiftUI)
import SwiftUI

@available(iOS 13.0, macOS 10.15, tvOS 13.0, watchOS 6.0, *)
public extension View {
    /// Records `$screen` with this name each time the view appears (`auto: false`), on every platform.
    /// Use it on SwiftUI screens that automatic capture can't name, or to pick your own name. Automatic capture
    /// skips a screen whose view carries this modifier, and the same name twice in a row is sent once.
    ///
    /// ```swift
    /// PaywallView().omniScreen("Paywall")
    /// ```
    func omniScreen(_ name: String) -> some View {
        modifier(OmniScreenModifier(name: name))
    }
}

/// Its type name (`Omni.OmniScreenModifier`) shows up in the hosting controller's type, which is how automatic
/// capture knows the view names itself (see `ScreenName.namedByAppMarker`).
@available(iOS 13.0, macOS 10.15, tvOS 13.0, watchOS 6.0, *)
struct OmniScreenModifier: ViewModifier {
    let name: String

    func body(content: Content) -> some View {
        content.onAppear { Omni.observedScreen(name, auto: false) }
    }
}
#endif
