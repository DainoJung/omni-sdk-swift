import Foundation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Listens for the app going to the foreground / background and tells the client.
/// Always installed: flushing on background and session timing don't depend on `captureLifecycle`;
/// the client decides whether to emit `$app_opened`.
final class LifecycleObserver {
    private let center: NotificationCenter
    private var tokens: [NSObjectProtocol] = []

    init(client: OmniClient, center: NotificationCenter = .default) {
        self.center = center
        #if canImport(UIKit)
        tokens.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: nil) { [weak client] _ in
            client?.appDidBecomeActive()
        })
        tokens.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil) { [weak client] _ in
            guard let client else { return }
            AppState.runInBackgroundTask { done in
                client.appDidEnterBackground(completion: done)
            }
        })
        #elseif canImport(AppKit)
        // macOS has no background state; losing focus is the closest thing.
        tokens.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: nil) { [weak client] _ in
            client?.appDidBecomeActive()
        })
        tokens.append(center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: nil) { [weak client] _ in
            client?.appDidEnterBackground(completion: nil)
        })
        #endif
    }

    deinit {
        tokens.forEach(center.removeObserver)
    }
}

enum AppState {
    /// True only when we can tell for sure the app was launched into the background
    /// (background fetch, push), so the cold-start `$app_opened` waits for the app to be opened.
    static func isInBackground() -> Bool {
        #if canImport(UIKit) && !targetEnvironment(macCatalyst)
        guard Thread.isMainThread else { return false }
        return MainActor.assumeIsolated {
            sharedApplication()?.applicationState == .background
        }
        #else
        return false
        #endif
    }

    #if canImport(UIKit)
    /// `UIApplication.shared` without referencing it directly, so the package also compiles
    /// for app extensions (where there is no shared application).
    @MainActor
    static func sharedApplication() -> UIApplication? {
        guard !Bundle.main.bundlePath.hasSuffix(".appex") else { return nil }
        return UIApplication.value(forKeyPath: "sharedApplication") as? UIApplication
    }

    /// Keeps the app alive in the background while `work` runs; `work` calls `done` when finished.
    static func runInBackgroundTask(_ work: @escaping (_ done: @escaping () -> Void) -> Void) {
        guard Thread.isMainThread else { work {}; return }
        MainActor.assumeIsolated {
            guard let app = sharedApplication() else { work {}; return }
            let task = BackgroundTask(app: app)
            task.begin()
            work { DispatchQueue.main.async { MainActor.assumeIsolated { task.end() } } }
        }
    }
    #endif
}

#if canImport(UIKit)
@MainActor
private final class BackgroundTask {
    private let app: UIApplication
    private var id: UIBackgroundTaskIdentifier = .invalid

    init(app: UIApplication) { self.app = app }

    func begin() {
        id = app.beginBackgroundTask(withName: "app.omnigrowth.sdk.flush") { [self] in
            MainActor.assumeIsolated { self.end() }
        }
    }

    func end() {
        guard id != .invalid else { return }
        app.endBackgroundTask(id)
        id = .invalid
    }
}
#endif
