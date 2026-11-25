import InvestiQCore
import InvestiQData
#if canImport(FoundationModels)
import FoundationModels

/// Apple Foundation Models (on-device, macOS 26+ on supported Macs). Nothing leaves the Mac; no tools are
/// given to the session. Returns nil when the system model is not available (unsupported device, Apple
/// Intelligence off, model not downloaded).
@available(macOS 26.0, *)
public struct AppleOnDeviceAIProvider: AIProvider {
    public let kind = AIProviderKind.appleOnDevice
    public let sendsDataOffDevice = false

    public init?() {
        guard case .available = SystemLanguageModel.default.availability else { return nil }
    }

    public func complete(system: String, prompt: String, schema: [String: any Sendable]) async throws -> String {
        let session = LanguageModelSession(instructions: system)
        do {
            return try await session.respond(to: prompt).content
        } catch {
            throw AIError.providerUnavailable
        }
    }
}
#endif

/// Factory used by the app: an on-device provider where the OS and device support it, otherwise nil.
public enum OnDeviceAI {
    public static func provider() -> (any AIProvider)? {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) { return AppleOnDeviceAIProvider() }
        #endif
        return nil
    }
}
