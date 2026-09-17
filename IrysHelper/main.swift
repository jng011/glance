//
//  main.swift
//  IrysHelper — privileged daemon for Irys.
//
//  Runs as root, launched on demand by launchd, registered once by the app
//  through SMAppService. Holds the session key so it survives the app quitting
//  and the Mac restarting, which is what removes the repeated Touch ID prompts.
//
//  THE SECURITY MODEL, because this is the part that matters:
//
//  This daemon hands back the session key — which decrypts the user's login
//  password — to a caller with no human present. That is the feature. The only
//  thing between that and any other process on the machine is the code signature
//  check in `ListenerDelegate.isCallerTrusted`. It is not a nicety, it is the
//  entire access control.
//
//  The key lives in a root-owned 0600 file rather than a keychain. A daemon has
//  no login keychain to unlock, and the System keychain would put the material
//  behind no stronger a barrier than the file does while implying otherwise.
//  FileVault protects it at rest.
//

import Foundation
import Security
import os

private let log = Logger(subsystem: "com.jng011.irys", category: "helper")

/// Bumped whenever the protocol or storage format changes, so the app can detect
/// a daemon left behind by an older install instead of talking to it.
private let helperBuildVersion = "1"

/// Root-only storage. /Library/Application Support rather than /var/tmp or
/// /private/var: documented location, survives OS updates, not periodically swept.
private let storageDirectory = "/Library/Application Support/Irys"
private let storagePath = storageDirectory + "/session.key"

// MARK: - Storage

private func readKey() -> Data? {
    guard let data = FileManager.default.contents(atPath: storagePath), !data.isEmpty else { return nil }
    return data
}

private func writeKey(_ key: Data?) -> Bool {
    let fm = FileManager.default

    guard let key else {
        // An absent file is the requested state, so a missing-file error is success.
        if fm.fileExists(atPath: storagePath) {
            do { try fm.removeItem(atPath: storagePath) } catch {
                log.error("could not remove key: \(error.localizedDescription, privacy: .public)")
                return false
            }
        }
        return true
    }

    do {
        var isDirectory: ObjCBool = false
        if !fm.fileExists(atPath: storageDirectory, isDirectory: &isDirectory) {
            // 0700 set at creation rather than chmod'd afterwards: the latter
            // leaves a window in which the directory is world-traversable.
            try fm.createDirectory(
                atPath: storageDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: 0o700)]
            )
        }

        // Write to a temp file, then rename. `replaceItemAt` is deliberately not
        // used: it requires the destination to already exist, so the very first
        // write would fail. rename(2) via moveItem is atomic within a filesystem
        // and works whether or not the destination is there.
        let tmpPath = storagePath + ".tmp"
        if fm.fileExists(atPath: tmpPath) { try? fm.removeItem(atPath: tmpPath) }
        guard fm.createFile(
            atPath: tmpPath,
            contents: key,
            attributes: [.posixPermissions: NSNumber(value: 0o600)]
        ) else {
            log.error("could not create temporary key file")
            return false
        }
        if fm.fileExists(atPath: storagePath) { try fm.removeItem(atPath: storagePath) }
        try fm.moveItem(atPath: tmpPath, toPath: storagePath)
        return true
    } catch {
        log.error("writeKey failed: \(error.localizedDescription, privacy: .public)")
        return false
    }
}

// MARK: - Service

final class HelperService: NSObject, IrysHelperProtocol {
    func helperVersion(reply: @escaping (String) -> Void) {
        reply(helperBuildVersion)
    }

    func sessionKey(reply: @escaping (Data?) -> Void) {
        reply(readKey())
    }

    func setSessionKey(_ key: Data?, reply: @escaping (Bool) -> Void) {
        reply(writeKey(key))
    }
}

// MARK: - Connection admission

final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    /// The only caller allowed to talk to this daemon.
    ///
    /// Every clause is load-bearing:
    ///   - `identifier` pins the exact app
    ///   - `certificate leaf[subject.OU]` pins the Developer ID team
    ///   - `anchor apple generic` demands an Apple-issued chain, so a self-signed
    ///     binary claiming the same identifier is refused
    ///
    /// There is deliberately no relaxed variant for unsigned or ad-hoc builds. A
    /// debug convenience here would be an authentication bypass shipped to users.
    private static let requirementString = """
        identifier "com.jng011.irys" \
        and anchor apple generic \
        and certificate leaf[subject.OU] = "6TTTJ5468H"
        """

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection conn: NSXPCConnection) -> Bool {
        guard isCallerTrusted(conn) else {
            log.error("rejected connection from pid \(conn.processIdentifier, privacy: .public)")
            return false
        }
        conn.exportedInterface = NSXPCInterface(with: IrysHelperProtocol.self)
        conn.exportedObject = HelperService()
        conn.resume()
        return true
    }

    /// Validates the connecting process against `requirementString`.
    ///
    /// Identifies the caller by audit token, not pid. A pid can be recycled
    /// between the check and the call, which is the classic way this kind of
    /// check is defeated; the audit token names a specific process instance.
    private func isCallerTrusted(_ conn: NSXPCConnection) -> Bool {
        // `auditToken` is SPI reached through KVC, and it returns an NSValue
        // boxing an audit_token_t — not Data. Treating it as Data silently fails
        // every check, which would look like "the helper never answers".
        guard let boxed = conn.value(forKey: "auditToken") as? NSValue else {
            // Refusing on absence is the only safe direction: the alternative is
            // admitting an unverified caller to a root service.
            log.error("no audit token available — refusing")
            return false
        }
        var token = audit_token_t()
        boxed.getValue(&token, size: MemoryLayout<audit_token_t>.size)
        let tokenData = withUnsafeBytes(of: &token) { Data($0) }

        var code: SecCode?
        let attributes = [kSecGuestAttributeAudit: tokenData] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess,
              let code else {
            log.error("could not resolve the caller's code object")
            return false
        }

        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(Self.requirementString as CFString, [], &requirement) == errSecSuccess,
              let requirement else {
            log.error("could not compile the code requirement")
            return false
        }

        let status = SecCodeCheckValidity(code, [], requirement)
        guard status == errSecSuccess else {
            log.error("caller failed the code requirement: \(status, privacy: .public)")
            return false
        }
        return true
    }
}

let delegate = ListenerDelegate()
let listener = NSXPCListener(machServiceName: irysHelperMachServiceName)
listener.delegate = delegate
listener.resume()
log.info("IrysHelper \(helperBuildVersion, privacy: .public) listening")
// launchd starts this on demand and expects it to stay resident while connections
// are open; returning from main would terminate the service mid-request.
RunLoop.main.run()
