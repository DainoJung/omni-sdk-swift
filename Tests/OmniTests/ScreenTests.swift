import XCTest
@testable import Omni

final class ScreenNameTests: XCTestCase {
    private func name(_ typeName: String) -> String? { ScreenName.from(typeName: typeName) }

    func testUIKitControllers() {
        XCTAssertEqual(name("Scribo.WordListViewController"), "WordList")
        XCTAssertEqual(name("Scribo.SettingsController"), "Settings")
        XCTAssertEqual(name("Scribo.Onboarding"), "Onboarding")
        XCTAssertEqual(name("Scribo.Onboarding.StepViewController"), "Step")
        XCTAssertEqual(name("Scribo.PaywallHostingController"), "Paywall")
        XCTAssertEqual(name("Scribo.ListViewController<Scribo.Word>"), "List")
        XCTAssertEqual(name("Scribo.ViewController"), "ViewController") // nothing left to strip to
        XCTAssertEqual(name("  Scribo.WordListViewController\n"), "WordList")
        // Objective-C app classes reflect without a module.
        XCTAssertEqual(name("SCRWordListViewController"), "SCRWordList")
        // Third-party packages count as the app's.
        XCTAssertEqual(name("RevenueCatUI.PaywallViewController"), "Paywall")
    }

    func testPrivateAndLocalTypes() {
        XCTAssertEqual(name("Scribo.(unknown context at $10a3c4f20).WordListViewController"), "WordList")
        XCTAssertEqual(name("Scribo.(PaywallViewController in _3A9F2C1B7E)"), "Paywall")
        XCTAssertEqual(
            name("SwiftUI.UIHostingController<Scribo.(unknown context at $1d44ce89c).PaywallView>"),
            "Paywall"
        )
    }

    func testSwiftUIHostingControllers() {
        XCTAssertEqual(name("SwiftUI.UIHostingController<Scribo.PaywallView>"), "Paywall")
        XCTAssertEqual(
            name("SwiftUI.UIHostingController<SwiftUI.ModifiedContent<Scribo.PaywallView, SwiftUI._EnvironmentKeyWritingModifier<Swift.Optional<Swift.String>>>>"),
            "Paywall"
        )
        XCTAssertEqual(
            name("SwiftUI.UIHostingController<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<Scribo.PaywallView, SwiftUI._PaddingLayout>, SwiftUI._EnvironmentKeyWritingModifier<Foundation.Locale>>>"),
            "Paywall"
        )
        // A name ending in View wins over other app types (modifiers, models) that come first.
        XCTAssertEqual(
            name("SwiftUI.UIHostingController<SwiftUI.ModifiedContent<Scribo.Card<Scribo.Word>, Scribo.WordDetailView>>"),
            "WordDetail"
        )
        // Without a …View, the first app type.
        XCTAssertEqual(name("SwiftUI.UIHostingController<SwiftUI.ModifiedContent<Scribo.Home, SwiftUI._PaddingLayout>>"), "Home")
        XCTAssertEqual(name("SwiftUI.UIHostingController<SwiftUI._ConditionalContent<Scribo.LoginView, Scribo.HomeView>>"), "Login")
        XCTAssertEqual(name("SwiftUI.UIHostingController<SwiftUI.TupleView<(Scribo.HeaderView, Scribo.FeedView)>>"), "Header")
        XCTAssertEqual(name("_UIHostingController<Scribo.PaywallView>"), "Paywall")
        // AnyView contents, as read from a NavigationStack destination and a sheet.
        XCTAssertEqual(
            name("SwiftUI.(unknown context at $1d44ce89c).AnyViewStorage<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ParameterizedLazyView<Swift.Int, Scribo.WordDetailView>, SwiftUI.(unknown context at $1d3741898).ReadDestinationsModifier<SwiftUI.ResolvedNavigationDestinations>>, SwiftUI._PreferenceTransformModifier<SwiftUI.NavigationDestinationKey>>, SwiftUI.ModifiedContent<SwiftUI.NavigationSearchAdjustmentModifier, SwiftUI.InjectKeyModifier>>>"),
            "WordDetail"
        )
        XCTAssertEqual(
            name("SwiftUI.(unknown context at $1d44ce89c).AnyViewStorage<SwiftUI.ModifiedContent<SwiftUI.(unknown context at $1d3704ed4).SheetContent<SwiftUI.ModifiedContent<Scribo.PaywallView, SwiftUI._PaddingLayout>>, SwiftUI._EnvironmentKeyWritingModifier<SwiftUI.Binding<SwiftUI.PresentationMode>>>>"),
            "Paywall"
        )
        XCTAssertEqual(name("SwiftUI.UIHostingController<Scribo.View>"), "View")
    }

    func testSkipsSystemAndContainers() {
        for skipped in [
            "UINavigationController", "UITabBarController", "UISplitViewController", "UIPageViewController",
            "UIInputWindowController", "UIAlertController", "UIActivityViewController", "UIViewController",
            "UIKit.UINavigationController", "_UIRemoteViewController", "_UIAlertControllerTextFieldViewController",
            "SFSafariViewController", "MFMailComposeViewController", "PHPickerViewController",
            "PUPhotoPickerHostViewController", "SKStoreProductViewController", "AVPlayerViewController",
            "SwiftUI.UIKitNavigationController", "SwiftUI.UIKitTabBarController", "SwiftUI.TabHostingController",
            "SwiftUI.UIHostingController<SwiftUI.AnyView>",
            "SwiftUI.NavigationStackHostingController<SwiftUI.AnyView>",
            "SwiftUI.PresentationHostingController<SwiftUI.AnyView>",
            "SwiftUI.UIHostingController<SwiftUI.ModifiedContent<SwiftUI.AnyView, SwiftUI.RootModifier>>",
            "SwiftUI.UIHostingController<SwiftUI.Text>",
            "SwiftUI.AnyViewStorage<SwiftUI.ModifiedContent<SwiftUI._VariadicView.Tree<SwiftUI._VStackLayout, SwiftUI._VariadicView_Children>, SwiftUI.InjectKeyModifier>>",
            "Swift.Optional<Swift.Int>",
            "__C.UIViewController",
            "Scribo.MainNavigationController", "Scribo.RootTabBarController",
            "Scribo._PrivateViewController",
        ] {
            XCTAssertNil(name(skipped), skipped)
        }
    }

    func testSkipsWhatItCantParse() {
        for garbage in ["", "   ", "<>", "Scribo.", ".Foo", "Scribo..Foo", "(Swift.Int) -> ()", "1Scribo.Foo", "Scribo.(unclosed"] {
            XCTAssertNil(name(garbage), garbage)
        }
    }

    func testViewsThatNameThemselvesAreSkipped() {
        XCTAssertNil(name("SwiftUI.UIHostingController<SwiftUI.ModifiedContent<Scribo.PaywallView, Omni.OmniScreenModifier>>"))
        XCTAssertNil(name("SwiftUI.AnyViewStorage<SwiftUI.ParameterizedLazyView<Swift.Int, SwiftUI.ModifiedContent<Scribo.WordDetailView, Omni.OmniScreenModifier>>>"))
    }

    func testDeduperSkipsOnlyConsecutiveRepeats() {
        var d = ScreenDeduper()
        let sent = ["Home", "Home", "Paywall", "Paywall", "Home", "Settings", "Home"].filter { d.shouldSend($0) }
        XCTAssertEqual(sent, ["Home", "Paywall", "Home", "Settings", "Home"])
        d.record("Settings")
        XCTAssertFalse(d.shouldSend("Settings"))
        XCTAssertTrue(d.shouldSend("Home"))
    }
}

final class ScreenCaptureClientTests: XCTestCase {
    private func screens(_ h: Harness) -> [[String: Any]] {
        h.client.flush()
        h.drain()
        return h.transport.sentEvents
            .filter { $0["event"] as? String == "$screen" }
            .compactMap { $0["properties"] as? [String: Any] }
    }

    func testAutomaticScreensCarryAutoAndDedupe() {
        let h = Harness()
        h.client.observedScreen("Home", auto: true)
        h.client.observedScreen("Home", auto: true) // e.g. back after a full-screen modal
        h.client.observedScreen("Paywall", auto: true)
        h.client.observedScreen("Home", auto: true)
        h.client.observedScreen("  ", auto: true)
        let props = screens(h)
        XCTAssertEqual(props.compactMap { $0["name"] as? String }, ["Home", "Paywall", "Home"])
        XCTAssertEqual(props.compactMap { $0["auto"] as? Bool }, [true, true, true])
    }

    func testModifierScreensAreNotAutoAndShareDedupe() {
        let h = Harness()
        h.client.observedScreen("Paywall", auto: false)
        h.client.observedScreen("Paywall", auto: true)
        h.client.screen("Paywall") // explicit calls always go through
        h.client.observedScreen("Paywall", auto: false)
        let props = screens(h)
        XCTAssertEqual(props.count, 2)
        XCTAssertEqual(props[0]["auto"] as? Bool, false)
        XCTAssertNil(props[1]["auto"])
    }

    func testCaptureScreensOffSendsNoAutomaticScreens() {
        let h = Harness(options: Omni.Options(flushAt: 1000, flushInterval: 3600, captureLifecycle: false, captureScreens: false))
        h.client.observedScreen("Home", auto: true)
        h.client.observedScreen("Paywall", auto: true)
        XCTAssertEqual(h.allEventNames, [])
        // The modifier and Omni.screen are explicit, so they still work.
        h.client.observedScreen("Paywall", auto: false)
        h.client.screen("Settings")
        XCTAssertEqual(screens(h).compactMap { $0["name"] as? String }, ["Paywall", "Settings"])
    }

    func testResetForgetsTheLastScreen() {
        let h = Harness()
        h.client.observedScreen("Home", auto: true)
        h.client.reset()
        h.client.observedScreen("Home", auto: true)
        XCTAssertEqual(screens(h).count, 2)
    }

    func testCaptureScreensDefaultsOn() {
        XCTAssertTrue(Omni.Options().captureScreens)
    }
}
