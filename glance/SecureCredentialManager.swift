//
//  SecureCredentialManager.swift
//  glance
//
//  Two-tier storage on KeychainManager: a Touch-ID-gated session key (unwrapped once per launch) wraps an ungated encrypted
//  password blob, safe to read anytime — including the lock screen, where no app UI exists to host a Touch ID prompt.
//  Touch ID authorizes the session; nothing yet authorizes each individual unlock beyond that (face recognition will).
//

import Foundation
import CryptoKit
import LocalAuthentication

enum SecureCredentialError: LocalizedError {
    case emptyPassword
    case sessionLocked
    case encryptionFailed
    case decryptionFailed
    case sessionKeyUnavailable

    var errorDescription: String? {
        switch self {
        case .emptyPassword:
            return "Password cannot be empty."
        case .sessionLocked:
            return "Session is locked. Authenticate with Touch ID before storing or using the password."
        case .encryptionFailed:
            return "Encryption failed."
        case .decryptionFailed:
            return "Decryption failed. The stored credential may be corrupted."
        case .sessionKeyUnavailable:
            return "The session key is missing, but encrypted data still exists that only it could read. Nothing has been deleted. Remove the stored password on the Password tab to clear both and start fresh."
        }
    }
}

extension Notification.Name {
    /// Fires whenever the cached session key changes, so anything encrypted under it (e.g. `FaceEnrollmentStore`) can reload
    /// itself instead of relying on each call site to remember to — a past bug had the sidebar's unlock forget this, leaving
    /// face unlock silently running on stale pre-unlock data.
    static let secureCredentialSessionDidChange = Notification.Name("SecureCredentialManager.sessionDidChange")
}

enum SecureCredentialManager {
    nonisolated private static let sessionKeyAccount = "sessionKey"
    nonisolated private static let passwordBlobAccount = "encryptedPassword"

    // MARK: - Session state (thread-safe via NSLock)

    nonisolated private static let sessionLock = NSLock()
    nonisolated(unsafe) private static var _cachedKey: SymmetricKey?
    /// Last unlock or successful `readPassword` — what `SessionAutoLocker` compares against the idle limit. Guarded by
    /// `sessionLock` alongside the key so the two can never be observed out of step.
    nonisolated(unsafe) private static var _lastActivityAt: Date?

    nonisolated static var isSessionUnlocked: Bool {
        sessionLock.lock(); defer { sessionLock.unlock() }
        return _cachedKey != nil
    }

    /// `nil` whenever the session is locked — there is no activity to age.
    nonisolated static var lastActivityAt: Date? {
        sessionLock.lock(); defer { sessionLock.unlock() }
        return _lastActivityAt
    }

    nonisolated private static func cachedKey() -> SymmetricKey? {
        sessionLock.lock(); defer { sessionLock.unlock() }
        return _cachedKey
    }

    nonisolated private static func setCachedKey(_ key: SymmetricKey?) {
        sessionLock.lock()
        let changed = (key != nil) != (_cachedKey != nil)
        _cachedKey = key
        _lastActivityAt = key == nil ? nil : Date()
        sessionLock.unlock()
        // Posted after releasing the lock — observers may call back into `isSessionUnlocked` (re-acquiring it) from a
        // background thread, so posting while still locked risks a real self-deadlock, not a theoretical one.
        guard changed else { return }
        NotificationCenter.default.post(name: .secureCredentialSessionDidChange, object: nil)
    }

    /// Resets the idle countdown on each successful use, so an actively-used session never auto-locks.
    nonisolated private static func recordActivity() {
        sessionLock.lock()
        if _cachedKey != nil { _lastActivityAt = Date() }
        sessionLock.unlock()
    }

    // MARK: - Generic session-key crypto (shared by passwords here and face embeddings in SecureFaceStore; requires an unlocked session)

    nonisolated static func encrypt(_ plaintext: Data) throws -> Data {
        guard let key = cachedKey() else { throw SecureCredentialError.sessionLocked }
        do {
            let sealed = try AES.GCM.seal(plaintext, using: key)
            guard let combined = sealed.combined else { throw SecureCredentialError.encryptionFailed }
            return combined
        } catch {
            throw SecureCredentialError.encryptionFailed
        }
    }

    nonisolated static func decrypt(_ ciphertext: Data) throws -> Data {
        guard let key = cachedKey() else { throw SecureCredentialError.sessionLocked }
        do {
            let sealed = try AES.GCM.SealedBox(combined: ciphertext)
            return try AES.GCM.open(sealed, using: key)
        } catch {
            throw SecureCredentialError.decryptionFailed
        }
    }

    // MARK: - Public API

    nonisolated static func hasStoredPassword() -> Bool {
        KeychainManager.exists(account: passwordBlobAccount)
    }

    /// Prompts Touch ID and unwraps the session key, creating it Touch-ID-gated on first run. Caches only after a real gated
    /// read-back succeeds — `SecItemAdd` alone returns success even if the user hit Cancel on the auth UI, and bridging
    /// `LAContext.evaluatePolicy` synchronously via a semaphore deadlocks the thread pool and crashes the process.
    /// Must succeed before `savePassword`/`readPassword`. Blocking; call from a background task.
    nonisolated static func unlockSession(reason: String) throws {
        if cachedKey() != nil { return }

        // "Stay unlocked" mode. Two mechanisms, tried in order of how well they
        // protect the key.
        if GlanceSettings.staysUnlockedUntilRestartValue {
            // 1. The privileged daemon, when it is registered and answering. The key
            //    lives in root-owned storage and the daemon only hands it to a caller
            //    whose code signature matches, so a process merely running as this
            //    user cannot take it. This is the mechanism to prefer.
            if let data = HelperClient.storedSessionKey() {
                setCachedKey(SymmetricKey(data: data))
                return
            }

            // 2. Otherwise the key is in the Keychain without its .userPresence gate,
            //    which reads back with no prompt but is readable by anything running
            //    as this user. Weaker, and the fallback rather than the design.
            if KeychainManager.exists(account: sessionKeyAccount),
               let data = try? KeychainManager.read(account: sessionKeyAccount, context: nil) {
                setCachedKey(SymmetricKey(data: data))
                return
            }
        }

        // The existence check, not the read, decides whether a key gets created (load-bearing): a cancelled Touch ID prompt on
        // a user-presence item reports `errSecItemNotFound`, indistinguishable from no key — deciding on the read's error would
        // mint a fresh key (destroying the one that decrypts existing data) on every mis-tap.
        if KeychainManager.exists(account: sessionKeyAccount) {
            let context = LAContext()
            context.localizedReason = reason
            let data = try KeychainManager.read(account: sessionKeyAccount, context: context)
            setCachedKey(SymmetricKey(data: data))
            return
        }

        // No key at all, but minting one is still destructive if data is already encrypted under a previous key (e.g. a
        // re-signed dev build) — refuse rather than silently render it unreadable forever.
        guard !hasSessionEncryptedData else {
            throw SecureCredentialError.sessionKeyUnavailable
        }

        let key = SymmetricKey(size: .bits256)
        // A key minted while "stay unlocked" is on must be stored ungated from the
        // start; creating it gated and migrating immediately would put a Touch ID
        // prompt in front of a user who switched the setting on precisely to stop
        // seeing them.
        let access = GlanceSettings.staysUnlockedUntilRestartValue
            ? nil
            : try KeychainManager.makeUserPresenceAccessControl()
        try KeychainManager.save(
            account: sessionKeyAccount,
            data: key.withUnsafeBytes { Data($0) },
            accessControl: access
        )

        // Read back through the gated path rather than trusting the write — only a real read proves authentication happened.
        let readBackContext = LAContext()
        readBackContext.localizedReason = reason
        let data = try KeychainManager.read(account: sessionKeyAccount, context: readBackContext)
        setCachedKey(SymmetricKey(data: data))
    }

    /// Checked without needing the key itself, so this stays answerable precisely when the key can't be read.
    nonisolated static var hasSessionEncryptedData: Bool {
        KeychainManager.exists(account: passwordBlobAccount) || SecureFaceStore.exists
    }

    /// Clears the cached session key. Next save/read requires Touch ID again.
    nonisolated static func lockSession() {
        setCachedKey(nil)
    }

    /// Moves the existing session key between Touch-ID-gated and ungated storage.
    ///
    /// Re-stores the SAME key rather than minting a new one — a new key would leave
    /// the stored password and every enrolled face encrypted under a key that no
    /// longer exists, which is unrecoverable.
    ///
    /// Turning this ON is a real security downgrade, not a theoretical one: with
    /// `.userPresence` removed, any process running as this user can read the key
    /// out of the Keychain and decrypt the Mac password with it. What it buys is
    /// that the session survives the app quitting and the Mac restarting, so Touch
    /// ID is asked for once per macOS login instead of repeatedly.
    ///
    /// Blocking, and prompts Touch ID once when leaving the gated state. Call from a
    /// background task.
    nonisolated static func setStaysUnlocked(_ enabled: Bool, reason: String) throws {
        // Reading the key is what proves we can migrate it at all; do this before
        // deleting anything, so a cancelled prompt leaves the old item untouched.
        try unlockSession(reason: reason)
        guard let key = cachedKey() else { throw SecureCredentialError.sessionKeyUnavailable }
        let material = key.withUnsafeBytes { Data($0) }

        // Prefer the daemon when it is actually answering. Registration status alone
        // is not enough — a daemon can be registered but awaiting approval in Login
        // Items, in which case it will not respond and the key must go somewhere the
        // app can still read it.
        let usingHelper = enabled && HelperClient.isReachable()
        if usingHelper {
            guard HelperClient.storeSessionKey(material) else {
                throw SecureCredentialError.sessionKeyUnavailable
            }
            // The Keychain copy stays Touch-ID-gated. Two protected copies is
            // strictly better than one unprotected one, and it means disabling the
            // daemon later falls back to a gated key rather than to nothing.
        } else if !enabled {
            // Leaving the feature: clear the daemon's copy so a stale key cannot be
            // served to anything after the user has asked for the gate back.
            HelperClient.storeSessionKey(nil)
        }

        // Ungate the Keychain item only when the daemon is NOT holding the key —
        // otherwise this would quietly leave a second, unprotected copy behind and
        // undo the point of using the daemon at all.
        let access = (enabled && !usingHelper)
            ? nil
            : try KeychainManager.makeUserPresenceAccessControl()
        // `save` deletes any existing item for this account before adding, so this is
        // a replace rather than a duplicate.
        try KeychainManager.save(account: sessionKeyAccount, data: material, accessControl: access)

        // Keep the key cached across the migration: dropping it here would demand a
        // fresh Touch ID prompt immediately after the user asked for fewer of them.
        setCachedKey(key)
    }

    /// Encrypts and stores `passwordBytes`. Requires an unlocked session —
    /// call `unlockSession(reason:)` first. Blocking; call from a background task.
    nonisolated static func savePassword(_ passwordBytes: Data) throws {
        guard !passwordBytes.isEmpty else { throw SecureCredentialError.emptyPassword }
        let combined = try encrypt(passwordBytes)
        try KeychainManager.save(account: passwordBlobAccount, data: combined)
    }

    /// No separate Touch ID prompt — only the session key was gated, at unlock time. Caller MUST zero the returned bytes via
    /// `.resetBytes(in:)` after use. Blocking; call from a background task.
    nonisolated static func readPassword() throws -> Data {
        guard cachedKey() != nil else { throw SecureCredentialError.sessionLocked }
        let ciphertext = try KeychainManager.read(account: passwordBlobAccount)
        let plaintext = try decrypt(ciphertext)
        // Only on success: a failed read shouldn't extend the idle window.
        recordActivity()
        return plaintext
    }

    /// Deletes both Keychain items and clears the cached session key.
    nonisolated static func deletePassword() throws {
        try KeychainManager.delete(account: passwordBlobAccount)
        try KeychainManager.delete(account: sessionKeyAccount)
        setCachedKey(nil)
    }
}
