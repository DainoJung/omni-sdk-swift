#if canImport(UIKit) && !os(watchOS)
import XCTest
import SwiftUI
import UIKit
@testable import Omni

// Runs on the iOS / tvOS simulator only (`xcodebuild test`); `swift test` on macOS skips it.

final class ListViewController: UIViewController {}
final class DetailViewController: UIViewController {}

struct ProbePaywallView: View { var body: some View { Text("pay") } }
struct ProbeDetailView: View { var body: some View { Text("detail") } }
struct ProbeHomeView: View { var body: some View { Text("home") } }

struct ProbeRootView<Destination: View>: View {
    var path: [Int]
    var sheet = false
    @ViewBuilder var destination: () -> Destination

    var body: some View {
        TabView {
            NavigationStack(path: .constant(path)) {
                ProbeHomeView().navigationDestination(for: Int.self) { _ in destination() }
            }.tabItem { Text("a") }
            ProbePaywallView().tabItem { Text("b") }
        }.sheet(isPresented: .constant(sheet)) { ProbePaywallView().padding() }
    }
}

@MainActor
final class ScreenCaptureUIKitTests: XCTestCase {
    private var sent: [String] = []
    private var window: UIWindow!

    private func prepare() {
        sent = []
        ScreenCapture.install()
        ScreenCapture.install() // idempotent
        var deduper = ScreenDeduper() // what the client does with them
        ScreenCapture.send = { [weak self] in if deduper.shouldSend($0) { self?.sent.append($0) } }
        window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        addTeardownBlock { @MainActor [self] in
            window.isHidden = true
            window = nil
            ScreenCapture.send = { Omni.observedScreen($0, auto: true) }
        }
    }

    private func show(_ root: UIViewController) {
        if window == nil { prepare() }
        window.rootViewController = root
        window.makeKeyAndVisible()
        settle()
    }

    private func settle(_ seconds: TimeInterval = 1) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private func frontName() -> String? {
        ScreenCapture.name(for: ScreenCapture.frontmost(window.rootViewController!))
    }

    func testUIKitNavigationSendsTopScreen() {
        let nav = UINavigationController(rootViewController: ListViewController())
        show(nav)
        nav.pushViewController(DetailViewController(), animated: false)
        settle()
        nav.popViewController(animated: false)
        settle()
        XCTAssertEqual(Array(sent.drop(while: { $0 != "List" })), ["List", "Detail", "List"])
    }

    func testSwiftUIHostingControllerIsNamedFromItsView() {
        show(UIHostingController(rootView: ProbePaywallView().padding()))
        XCTAssertEqual(frontName(), "ProbePaywall")
        XCTAssertEqual(sent.last, "ProbePaywall")
    }

    func testSwiftUINavigationStackDestinationAndSheet() {
        // A NavigationStack's root view reaches its hosting controller type-erased, so it has no name.
        show(UIHostingController(rootView: ProbeRootView(path: []) { ProbeDetailView() }))
        XCTAssertNil(frontName())

        show(UIHostingController(rootView: ProbeRootView(path: [1]) { ProbeDetailView() }))
        XCTAssertEqual(frontName(), "ProbeDetail")
        XCTAssertEqual(sent.last, "ProbeDetail")

        show(UIHostingController(rootView: ProbeRootView(path: [], sheet: true) { ProbeDetailView() }))
        XCTAssertEqual(frontName(), "ProbePaywall")
    }

    func testOmniScreenModifierTurnsOffAutomaticName() {
        show(UIHostingController(rootView: ProbePaywallView().omniScreen("Paywall")))
        XCTAssertNil(frontName())

        show(UIHostingController(rootView: ProbeRootView(path: [1]) { ProbeDetailView().omniScreen("Detail") }))
        XCTAssertNil(frontName())
    }
}
#endif
