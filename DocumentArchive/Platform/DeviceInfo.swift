import Foundation

/// The device and system for the diagnostics report: nothing that identifies the user or the
/// device itself (no name, no serial number).
enum DeviceInfo {
    /// "macOS", "iOS" or "iPadOS".
    static var systemName: String {
        #if os(macOS)
        "macOS"
        #else
        ProcessInfo.processInfo.isiOSAppOnMac ? "macOS (iOS app)"
            : modelIdentifier.hasPrefix("iPad") ? "iPadOS" : "iOS"
        #endif
    }

    /// E.g. "26.0.1".
    static var systemVersion: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    /// The hardware model, e.g. "Mac15,3" or "iPhone17,3"; in the simulator the simulated model.
    static var modelIdentifier: String {
        #if os(macOS)
        sysctlString("hw.model") ?? "Mac"
        #else
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
            return "\(simulated) (Simulator)"
        }
        return sysctlString("hw.machine") ?? "unknown"
        #endif
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }
}
