import Foundation

/// Marker so the module is never empty on non-Apple platforms (the adapters are `#if`-guarded).
public enum PlatformApple {
    public static var isSupported: Bool {
        #if canImport(Security) && canImport(LocalAuthentication)
        return true
        #else
        return false
        #endif
    }
}
