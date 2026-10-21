import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// The static part of `context`, collected once at configure.
struct DeviceInfo: Equatable {
    var appVersion: String?
    var build: String?
    var platform: String
    var deviceType: String
    var locale: String?
    var osVersion: String?
    var deviceModel: String?

    static func collect(bundle: Bundle = .main) -> DeviceInfo {
        let info = bundle.infoDictionary
        let (platform, deviceType) = platformAndDeviceType()
        return DeviceInfo(
            appVersion: info?["CFBundleShortVersionString"] as? String,
            build: info?["CFBundleVersion"] as? String,
            platform: platform,
            deviceType: deviceType,
            locale: localeIdentifier(Locale.current),
            osVersion: osVersion(),
            deviceModel: deviceModel()
        )
    }

    /// `ko_KR@calendar=…` → `ko-KR`
    static func localeIdentifier(_ locale: Locale) -> String? {
        let id = locale.identifier.split(separator: "@").first.map(String.init) ?? ""
        return id.isEmpty ? nil : id.replacingOccurrences(of: "_", with: "-")
    }

    static func osVersion() -> String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return v.patchVersion > 0
            ? "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
            : "\(v.majorVersion).\(v.minorVersion)"
    }

    static func platformAndDeviceType() -> (platform: String, deviceType: String) {
        #if targetEnvironment(macCatalyst)
        return ("macos", "desktop")
        #elseif os(iOS)
        if ProcessInfo.processInfo.isiOSAppOnMac { return ("macos", "desktop") }
        let idiom = onMain { UIDevice.current.userInterfaceIdiom }
        switch idiom {
        case .pad: return ("ipados", "tablet")
        case .phone: return ("ios", "phone")
        default: return ("other", "other")
        }
        #elseif os(macOS)
        return ("macos", "desktop")
        #else
        return ("other", "other") // tvOS and anything else
        #endif
    }

    /// `iPhone17,3` on devices (hw.machine), the simulated model on the simulator, `Mac14,2` on Macs (hw.model).
    static func deviceModel() -> String? {
        #if os(macOS) || targetEnvironment(macCatalyst)
        return sysctlString("hw.model")
        #else
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"], !simulated.isEmpty {
            return simulated
        }
        #if os(iOS)
        if ProcessInfo.processInfo.isiOSAppOnMac { return sysctlString("hw.model") }
        #endif
        return sysctlString("hw.machine")
        #endif
    }

    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        let value = buffer.withUnsafeBufferPointer { ptr -> String in
            guard let base = ptr.baseAddress else { return "" }
            return String(cString: base)
        }
        return value.isEmpty ? nil : value
    }
}

/// Runs `body` on the main thread and returns its result (inline when already on main).
func onMain<T: Sendable>(_ body: @MainActor () -> T) -> T {
    if Thread.isMainThread {
        return MainActor.assumeIsolated(body)
    }
    return DispatchQueue.main.sync { MainActor.assumeIsolated(body) }
}
