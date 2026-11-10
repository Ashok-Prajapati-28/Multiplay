import AVFoundation
import Foundation

/// System audio recording permission ("System Audio Recording Only" in Privacy & Security).
///
/// There's no public API to ask for it, and on recent macOS versions a process tap doesn't
/// trigger the prompt by itself: capture just stays silent until a decision exists. So we
/// use the TCC calls that Apple's own apps use (as the open-source AudioCap sample does).
enum SystemAudioPermission {
    enum Status { case granted, denied, notAsked }

    private typealias PreflightFn = @convention(c) (CFString, CFDictionary?) -> Int32
    private typealias RequestFn = @convention(c) (CFString, CFDictionary?, @escaping @convention(block) (Bool) -> Void) -> Void
    private static let service = "kTCCServiceAudioCapture" as CFString
    private static let tcc = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)

    static var status: Status {
        guard let symbol = dlsym(tcc, "TCCAccessPreflight") else { return .notAsked }
        switch unsafeBitCast(symbol, to: PreflightFn.self)(service, nil) {
        case 0: return .granted
        case 1: return .denied
        default: return .notAsked
        }
    }

    /// Shows the macOS prompt if needed. Returns whether access is granted.
    static func request() async -> Bool {
        if status == .granted { return true }
        guard let symbol = dlsym(tcc, "TCCAccessRequest") else { return false }
        let request = unsafeBitCast(symbol, to: RequestFn.self)
        return await withCheckedContinuation { continuation in
            request(service, nil) { granted in continuation.resume(returning: granted) }
        }
    }
}
