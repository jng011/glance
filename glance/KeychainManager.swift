//
//  KeychainManager.swift
//  glance
//
//  Thin, password-agnostic wrapper around Keychain Services — save/read/delete/exists by account, plus a Touch-ID access control helper.
//

import Foundation
import Security
import LocalAuthentication

enum KeychainError: LocalizedError {
    case itemNotFound
    case unexpectedData
    case accessControlFailed(String)
    case authenticationFailed
    case osStatus(OSStatus)

    /// Every case says what the user can actually do about it.
    ///
    /// These strings are shown inline under the password field during onboarding,
    /// where a bare Security-framework message is worse than useless: it is
    /// alarming, unsearchable, and gives no next step. `errSecMissingEntitlement`
    /// in particular rendered as "Keychain error: A required entitlement is not
    /// present", which tells a user nothing they can act on and does not even
    /// hint that the build is at fault rather than their Mac.
    var errorDescription: String? {
        switch self {
        case .itemNotFound:
            return "That Keychain item is missing. Set up your password again to recreate it."
        case .unexpectedData:
            return "The stored Keychain item is in an unexpected format. "
                 + "Remove the stored password on the Password tab, then set it again."
        case .accessControlFailed(let msg):
            return "Couldn't set up Touch ID protection for the stored password (\(msg)). "
                 + "Check that Touch ID is enrolled in System Settings, then try again."
        case .authenticationFailed:
            return "Touch ID was cancelled or didn't match. Try again."
        case .osStatus(let status):
            return Self.actionable(for: status)
        }
    }

    /// Maps the handful of OSStatus values this app can realistically produce to
    /// something a user can act on, and falls back to the system string plus the
    /// numeric code for everything else — the code matters, because it is the only
    /// searchable part of an unrecognised failure.
    private static func actionable(for status: OSStatus) -> String {
        let system = SecCopyErrorMessageString(status, nil) as String? ?? "unknown error"
        switch status {
        case errSecMissingEntitlement:
            // Not the user's fault and not fixable by them. Say so, rather than
            // leaving them retrying a thing that cannot work.
            return "This build of Irys isn't signed correctly, so it can't use the Keychain "
                 + "(\(system)). Nothing you can change will fix it — please report this at "
                 + "github.com/jng011/glance/issues."
        case errSecUserCanceled:
            return "Touch ID was cancelled. Try again when you're ready."
        case errSecAuthFailed:
            return "Touch ID didn't match. Try again, or use your Mac password at the prompt."
        case errSecDuplicateItem:
            return "A stored password already exists. Remove it on the Password tab, then set a new one."
        case errSecInteractionNotAllowed:
            return "The Keychain is locked right now. Unlock your Mac and try again."
        case errSecNotAvailable:
            return "The Keychain isn't available yet. Wait a moment after logging in, then try again."
        default:
            return "Keychain error \(status): \(system). If this keeps happening, please report it at "
                 + "github.com/jng011/glance/issues."
        }
    }
}

enum KeychainManager {
    nonisolated static let service = "com.jng011.irys"

    /// Attributes-only existence check — never prompts, even for access-controlled items.
    nonisolated static func exists(account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        return status != errSecItemNotFound
    }

    /// Pass an `LAContext` to authorize a read on an access-controlled item — the OS presents the prompt during this call.
    nonisolated static func read(account: String, context: LAContext? = nil) throws -> Data {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        if let context {
            query[kSecUseAuthenticationContext as String] = context
        }
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { throw KeychainError.unexpectedData }
            return data
        case errSecItemNotFound:
            throw KeychainError.itemNotFound
        case errSecUserCanceled, errSecAuthFailed:
            throw KeychainError.authenticationFailed
        default:
            throw KeychainError.osStatus(status)
        }
    }

    /// Replaces any existing item. Pass `accessControl` to gate future reads behind Touch ID; `nil` for device-local, unlock-only.
    nonisolated static func save(account: String, data: Data, accessControl: SecAccessControl? = nil) throws {
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        var addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data
        ]
        if let accessControl {
            addQuery[kSecAttrAccessControl as String] = accessControl
        } else {
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        }

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.osStatus(status) }
    }

    nonisolated static func delete(account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.osStatus(status)
        }
    }

    /// `.userPresence` requires Touch ID or device password, with no separate no-hardware handling needed.
    nonisolated static func makeUserPresenceAccessControl() throws -> SecAccessControl {
        var accessError: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(
            kCFAllocatorDefault,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            .userPresence,
            &accessError
        ) else {
            let msg = (accessError?.takeRetainedValue() as Error?)?.localizedDescription ?? "unknown"
            throw KeychainError.accessControlFailed(msg)
        }
        return access
    }
}
