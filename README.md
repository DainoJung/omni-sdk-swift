# Omni SDK for Swift

Send product events from your iOS, iPadOS, macOS or tvOS app to [Omni](https://omnigrowth.app). It's small,
has no dependencies, queues events on the device and sends them in batches. It never blocks the main thread.

## Install

In Xcode, go to **File › Add Package Dependencies…** and enter:

```
https://github.com/DainoJung/omni-sdk-swift
```

Or add it to `Package.swift`:

```swift
.package(url: "https://github.com/DainoJung/omni-sdk-swift", from: "0.4.0")
// target: .product(name: "Omni", package: "omni-sdk-swift")
```

Requires iOS 15, macOS 12 or tvOS 15.

## Quick start

Configure Omni once, as early as possible. Use your app's public key (`opk_…`), which Omni shows you.

```swift
import SwiftUI
import Omni

@main
struct MyApp: App {
    init() {
        Omni.configure(key: "opk_…")
    }
    var body: some Scene { WindowGroup { ContentView() } }
}
```

If your app uses an AppDelegate, call it in `application(_:didFinishLaunchingWithOptions:)` instead.

Track what people do:

```swift
Omni.track("lesson_completed", properties: ["lesson": 3, "duration_s": 42])
Omni.screen("Paywall")
```

When someone signs in, tell Omni who they are. Pass `consent: true` only after they agreed to marketing email:

```swift
Omni.identify(user.id, traits: ["plan": "free"])
Omni.setEmail(user.email, consent: user.agreedToMarketingEmail)
```

Link purchases to product events. With RevenueCat, pass its app user id. With Stripe, pass the customer id (`cus_…`):

```swift
Omni.setBillingId(Purchases.shared.appUserID)
```

On sign-out:

```swift
Omni.reset() // new anonymous id; the user id is cleared
```

### Options

```swift
Omni.configure(key: "opk_…", options: .init(
    flushAt: 20,            // send when this many events are queued
    flushInterval: 30,      // …or at least this often (seconds)
    maxQueue: 1000,         // most events kept while offline (oldest dropped first)
    captureLifecycle: true, // $app_installed, $app_updated, $app_opened
    captureScreens: true,   // $screen each time a screen appears (iOS, tvOS)
    debug: false            // log to the console
))
```

## Screens

On iOS and tvOS, Omni records `$screen` each time a screen appears, so you see the path people take (onboarding,
paywall, …) without touching each screen. It works for UIKit and SwiftUI: the name comes from the screen's type
(`WordListViewController` → `WordList`, a `UIHostingController` showing `PaywallView` → `Paywall`, a `NavigationStack`
destination or sheet showing `WordDetailView` → `WordDetail`). System screens (alerts, keyboards, share sheets, Safari,
mail, photo pickers) and containers (navigation and tab bar controllers) are skipped, and the same screen twice in a row
counts once. These events carry `auto: true`.

Some SwiftUI screens have no type to go by: the app's root view, the first view inside a `NavigationStack`, and tabs
of a `TabView` that aren't a `NavigationStack`. Name those yourself, or any screen you'd rather name:

```swift
HomeView()
    .omniScreen("Home")
```

`.omniScreen` sends `$screen` when the view appears (on every platform, macOS included), and automatic capture leaves
that screen to it. Put it where the view is created (as above) rather than inside the view's `body`, or give it the same
name automatic capture would, so it isn't counted twice. `Omni.screen("Paywall")` still works anywhere.

To turn automatic screens off: `Omni.configure(key: "opk_…", options: .init(captureScreens: false))`. On macOS there are
no automatic screens; use `.omniScreen` or `Omni.screen`.

## Experiments (A/B tests)

Omni runs A/B tests in your app: it decides what runs, and each device picks its variant on its own, instantly, from a
copy of the experiments kept on the device (refreshed in the background). Ask where the screen is built:

```swift
struct PaywallView: View {
    var body: some View {
        // nil: not running, or this person isn't in it. Show what the app shows today.
        let headline = Omni.payload("paywall_headline")?["headline"]?.stringValue ?? "Go Pro"
        Text(headline)
    }
}
```

or branch on the variant's name:

```swift
if Omni.variant("paywall_layout") == "b" {
    CompactPaywall()
} else {
    Paywall() // control, and nil
}
```

The first `variant` or `payload` call for an experiment in a session tells Omni this person saw it (`$exposure`), so
call them where the screen appears, not at launch. A person keeps their variant on this device, also after signing out.

On the very first launch the experiments may not be on the device yet. For screens shown right away (onboarding), wait
for them, at most 2 seconds:

```swift
struct OnboardingView: View {
    @State private var variant: String?
    @State private var ready = false

    var body: some View {
        Group {
            if !ready { ProgressView() }
            else if variant == "short" { ShortOnboarding() }
            else { Onboarding() }
        }
        .task {
            await Omni.loadExperiments()
            variant = Omni.variant("onboarding_v2")
            ready = true
        }
    }
}
```

Payload values are `JSONValue`s: read them with `stringValue`, `intValue`, `doubleValue`, `boolValue`, `arrayValue`,
`objectValue`, or get plain values with `Omni.payload("key")?.mapValues(\.anyValue)`.

## Push notifications

Omni can send push notifications to your app's users (you add your APNs key in Omni). The SDK reports the device token,
the notification permission and opens of Omni's pushes. Pass the token every launch; it's only sent when it changed:

```swift
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        Omni.configure(key: "opk_…")
        UNUserNotificationCenter.current().delegate = self
        application.registerForRemoteNotifications()
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Omni.setPushToken(deviceToken)
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        // Records the open for Omni's pushes and hands back their deep link; other pushes return nil.
        if let url = Omni.trackPushOpened(response.notification.request.content.userInfo) {
            UIApplication.shared.open(url)
        }
        completionHandler()
    }
}

@main
struct MyApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    var body: some Scene { WindowGroup { ContentView() } }
}
```

Ask for permission when it makes sense in your app (`UNUserNotificationCenter.current().requestAuthorization`). Omni
reads the permission on launch and each time the app comes to the foreground, and reports it when it changed. Whether a
token is for APNs' sandbox (builds run from Xcode) or production (TestFlight, App Store) comes from the build's
provisioning profile. Add the Push Notifications capability in Xcode.

## Deleting a person

When someone deletes their account, call `Omni.deleteUser()`. Omni deletes everything it has about them (their events, traits
and email), and this device starts over as a new anonymous person.

## Standard events

Omni reads a few events by name in every app: `signup`, `onboarding_step` (`step`, `name`), `onboarding_completed`,
`paywall_viewed` (`paywall`, `placement`), `purchase_started` (`product_id`, `paywall`), `share` and `invite_sent`. Send
them where they happen, plus your app's own core action. Easiest: ask Omni for the install prompt and paste it into
your coding agent; it places your app's whole tracking plan and keeps the rules in `AGENTS.md`.

## What's collected

- The events you send, and their properties.
- With `captureLifecycle` on: app installed, app updated and app opened.
- With `captureScreens` on (iOS, tvOS): the name of each screen as it appears (from its type, see Screens).
- With every event: app version and build, platform, device type, device model (e.g. `iPhone17,3`), OS version,
  locale, a session id, a random anonymous id made on first launch, and your user id after `identify`.
- Experiments: which variant this person saw (`$exposure`). The variant is picked on the device from a random id that's
  never sent; the experiments are fetched from Omni with your app's key only.
- Push, when you use it: the APNs device token, its environment and your bundle id; the notification permission; which
  of Omni's pushes were opened.

What isn't collected: no IDFA or other advertising ids, no autocapture of taps, no screen contents, screenshots or
session recordings, and no location. Email and traits are sent only when you set them.

Queued events stay on the device until they're sent, and are retried with backoff when the network is down. The
package includes a privacy manifest (`PrivacyInfo.xcprivacy`).

## Opt-out

```swift
Omni.optOut()     // stops collection and deletes queued events; remembered across launches
Omni.optIn()      // resumes
Omni.isOptedOut   // current state
```

`optOut()` works before `configure`, so you can respect a choice made on a consent screen.

## License

MIT
