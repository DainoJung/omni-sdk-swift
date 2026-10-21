import Foundation
#if canImport(UIKit) && !os(watchOS)
import UIKit
import SwiftUI
import ObjectiveC

/// Automatic `$screen` (iOS, tvOS): `UIViewController.viewDidAppear(_:)` is swizzled once, and each time a
/// controller appears the screen now in front of the person (the top of its window's presented / navigation /
/// tab stack) is named with `ScreenName` and sent, unless it's the same screen as just before.
enum ScreenCapture {
    /// Lazily initialized globals run exactly once, even when raced from several threads.
    private static let installed: Void = swizzleViewDidAppear()

    static func install() {
        _ = installed
    }

    private static func swizzleViewDidAppear() {
        let selector = #selector(UIViewController.viewDidAppear(_:))
        guard let method = class_getInstanceMethod(UIViewController.self, selector) else { return }
        typealias Original = @convention(c) (UIViewController, Selector, Bool) -> Void
        let original = unsafeBitCast(method_getImplementation(method), to: Original.self)
        let replacement: @convention(block) (UIViewController, Bool) -> Void = { controller, animated in
            original(controller, selector, animated)
            guard Thread.isMainThread else { return }
            MainActor.assumeIsolated { ScreenCapture.didAppear(controller) }
        }
        method_setImplementation(method, imp_implementationWithBlock(replacement))
    }

    @MainActor
    static func didAppear(_ controller: UIViewController) {
        let root = controller.viewIfLoaded?.window?.rootViewController ?? controller
        guard let name = name(for: frontmost(root)) else { return }
        send(name)
    }

    /// Where automatic screens go (replaced in tests).
    @MainActor static var send: (String) -> Void = { Omni.observedScreen($0, auto: true) }

    /// The controller the person is looking at, from a window's root.
    @MainActor
    static func frontmost(_ controller: UIViewController) -> UIViewController {
        var current = controller
        for _ in 0..<32 {
            if let presented = current.presentedViewController, !presented.isBeingDismissed {
                current = presented
            } else if let nav = current as? UINavigationController, let top = nav.topViewController {
                current = top
            } else if let tabs = current as? UITabBarController, let selected = tabs.selectedViewController {
                current = selected
            } else if let split = current as? UISplitViewController, let last = split.viewControllers.last {
                current = last
            } else if let pages = current as? UIPageViewController, let page = pages.viewControllers?.first {
                current = page
            } else if let container = current.children.first(where: isContainer) {
                // e.g. a SwiftUI root hosting a TabView or NavigationStack, or a custom container around a tab bar.
                current = container
            } else {
                break
            }
        }
        return current
    }

    private static func isContainer(_ controller: UIViewController) -> Bool {
        controller is UINavigationController || controller is UITabBarController
            || controller is UISplitViewController || controller is UIPageViewController
    }

    @MainActor private static var names: [ObjectIdentifier: String?] = [:]

    /// The screen name for a controller's type (worked out once per type).
    @MainActor
    static func name(for controller: UIViewController) -> String? {
        // SwiftUI hosts `NavigationStack` destinations and sheets as `…HostingController<AnyView>`: the view inside
        // the AnyView names the screen.
        if let hosting = controller as? UIHostingController<AnyView> {
            return ScreenName.from(typeName: erasedTypeName(hosting.rootView))
        }
        let type = type(of: controller)
        if let cached = names[ObjectIdentifier(type)] { return cached }
        let name = ScreenName.from(typeName: String(reflecting: type))
        if names.count < 500 { names[ObjectIdentifier(type)] = name }
        return name
    }

    /// `SwiftUI.AnyViewStorage<Scribo.PaywallView>` for `AnyView(PaywallView())`, or "" when it can't be read.
    static func erasedTypeName(_ view: AnyView) -> String {
        guard let storage = Mirror(reflecting: view).children.first?.value else { return "" }
        return String(reflecting: type(of: storage))
    }
}
#else
/// No automatic screens on macOS (AppKit has no single screen-appeared hook to rely on): use `Omni.screen(...)`
/// or `.omniScreen(...)`.
enum ScreenCapture {
    static func install() {}
}
#endif
