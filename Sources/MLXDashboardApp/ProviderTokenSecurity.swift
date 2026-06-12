import AppKit
import Foundation
import LocalAuthentication

enum BiometricAuthorizationResult: Equatable {
    case authorized
    case cancelled
    case failed(String)
}

@MainActor
protocol BiometricAuthorizing {
    func authorize(reason: String) async -> BiometricAuthorizationResult
}

@MainActor
struct LocalBiometricAuthorizer: BiometricAuthorizing {
    func authorize(reason: String) async -> BiometricAuthorizationResult {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            return .failed(error?.localizedDescription ?? "Authentication is unavailable.")
        }

        return await withCheckedContinuation { continuation in
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, error in
                if success {
                    continuation.resume(returning: .authorized)
                    return
                }
                if let laError = error as? LAError {
                    switch laError.code {
                    case .userCancel, .systemCancel, .appCancel:
                        continuation.resume(returning: .cancelled)
                    default:
                        continuation.resume(returning: .failed(laError.localizedDescription))
                    }
                    return
                }
                continuation.resume(returning: .failed(error?.localizedDescription ?? "Authentication failed."))
            }
        }
    }
}

@MainActor
protocol ProviderTokenCopying {
    func copy(_ text: String)
}

@MainActor
struct PasteboardProviderTokenCopier: ProviderTokenCopying {
    func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}
