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
.package(url: "https://github.com/DainoJung/omni-sdk-swift", from: "0.1.0")
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
    debug: false            // log to the console
))
```

## What's collected

- The events you send, and their properties.
- With `captureLifecycle` on: app installed, app updated and app opened.
- With every event: app version and build, platform, device type, device model (e.g. `iPhone17,3`), OS version,
  locale, a session id, a random anonymous id made on first launch, and your user id after `identify`.

What isn't collected: no IDFA or other advertising ids, no autocapture of taps or screens, no screenshots or session
recordings, and no location. Email and traits are sent only when you set them.

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
