//
//  HelperClient.swift
//  Irys
//
//  App side of the privileged daemon. Registers it once through SMAppService and
//  talks to it over XPC.
//
//  Why a root daemon at all: the session key has to be readable at the lock
//  screen, where no Touch ID prompt can be shown. Keeping it in the app's memory
//  means it dies with the app; storing it ungated in the Keychain means any
//  process running as this user can read it. A daemon can hold it where the only
//  way in is a code-signature check — see `ListenerDelegate` in the helper.
//
//  Registration costs the user exactly one admin authentication, ever. macOS
//  verifies that password itself and discards it; nothing here ever sees it.
//

import Foundation
import ServiceManagement
import os

@MainActor
@Observable
final class HelperClient {
    static let shared = HelperClient()

    nonisolated private static let log = Logger(subsystem: "com.jng011.irys", category: "helperclient")

    /// Plist name, not the label — SMAppService looks the daemon up by the
    /// filename in Contents/Library/LaunchDaemons.
    private static let plistName = "com.jng011.irys.helper.plist"

    enum Availability: Equatable {
        case notRegistered
        /// Registered, but the user has to switch it on in System Settings >
        /// General > Login Items. macOS returns this rather than prompting when
        /// the user has previously disabled it.
        case requiresApproval
        case enabled
        case unavailable(String)
    }

    private(set) var availability: Availability = .notRegistered

    private init() { refresh() }

    // MARK: - Registration

    func refresh() {
        let service = SMAppService.daemon(plistName: Self.plistName)
        switch service.status {
        case .enabled: availability = .enabled
        case .requiresApproval: availability = .requiresApproval
        // .notFound and .notRegistered are BOTH "not installed yet".
        //
        // The name suggests a missing file, and it was mapped that way at first,
        // which hid the Install button behind an error that was never true. For a
        // daemon, macOS reports .notFound whenever Background Task Management has
        // no record of the item — which is exactly the state before the first
        // registration. Confirmed in smd's log: "getEffectiveDisposition: record
        // not found" followed by "Found status: 3", with the plist and the binary
        // both sitting correctly in the bundle.
        //
        // A genuinely missing helper surfaces as a thrown error from register(),
        // which is where it can be reported accurately.
        case .notRegistered, .notFound: availability = .notRegistered
        @unknown default: availability = .unavailable("Unknown helper status.")
        }
    }

    /// Registers the daemon. Shows one admin authentication prompt the first time.
    ///
    /// Throws rather than returning a Bool so the caller can put the real reason
    /// in front of the user; "it didn't work" is not something anyone can act on.
    func register() throws {
        let service = SMAppService.daemon(plistName: Self.plistName)
        do {
            try service.register()
            Self.log.info("helper registered")
        } catch {
            // Registering something already registered throws, and that is not a
            // failure. Rather than matching an error code — SMAppService does not
            // document a stable one, and the SMJobBless constants do not apply to
            // it — ask the service what state it actually ended up in.
            refresh()
            if availability == .enabled || availability == .requiresApproval {
                Self.log.info("register threw but the daemon is present: \(String(describing: self.availability), privacy: .public)")
                return
            }
            Self.log.error("register failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
        refresh()
    }

    func unregister() throws {
        let service = SMAppService.daemon(plistName: Self.plistName)
        try service.unregister()
        refresh()
    }

    /// Opens the Login Items pane so the user can approve a daemon macOS has
    /// parked in `requiresApproval`. There is no programmatic way to approve it —
    /// that is the point of the state.
    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    // MARK: - Key custody

    /// A fresh connection per call rather than a cached one.
    ///
    /// The daemon is launched on demand and can exit between requests; a cached
    /// connection would go invalid silently and every later call would fail with
    /// no obvious cause. Connections are cheap relative to how rarely this runs.
    nonisolated private static func makeConnection() -> NSXPCConnection {
        let conn = NSXPCConnection(machServiceName: irysHelperMachServiceName, options: .privileged)
        conn.remoteObjectInterface = NSXPCInterface(with: IrysHelperProtocol.self)
        conn.resume()
        return conn
    }

    /// Blocking XPC round-trip.
    ///
    /// `SecureCredentialManager` is nonisolated and blocking by design, and its
    /// callers already run it off the main thread. The timeout is what makes a
    /// semaphore safe here: without it, a daemon that fails to launch — refused
    /// by the user in Login Items, say — would hang the calling thread forever
    /// instead of falling back to the Keychain path.
    nonisolated private static func withProxy<T>(
        timeout: TimeInterval = 5,
        _ body: @escaping (IrysHelperProtocol, @escaping (T) -> Void) -> Void
    ) -> T? {
        let conn = makeConnection()
        defer { conn.invalidate() }

        let semaphore = DispatchSemaphore(value: 0)
        var result: T?

        guard let proxy = conn.remoteObjectProxyWithErrorHandler({ error in
            log.error("XPC error: \(error.localizedDescription, privacy: .public)")
            // Signal on failure too, or the timeout below becomes the only exit
            // and every error costs a full five seconds.
            semaphore.signal()
        }) as? IrysHelperProtocol else {
            return nil
        }

        body(proxy) { value in
            result = value
            semaphore.signal()
        }

        _ = semaphore.wait(timeout: .now() + timeout)
        return result
    }

    /// Reads the key the daemon is holding. `nil` if the daemon is unreachable or
    /// has none, which the caller must treat as "fall back", not as "no key".
    nonisolated static func storedSessionKey() -> Data? {
        withProxy { proxy, done in
            proxy.sessionKey { done($0) }
        } ?? nil
    }

    @discardableResult
    nonisolated static func storeSessionKey(_ key: Data?) -> Bool {
        withProxy { proxy, done in
            proxy.setSessionKey(key) { done($0) }
        } ?? false
    }

    /// Whether a daemon is actually answering, as opposed to merely registered.
    /// Registration status and reachability disagree often enough — approval
    /// pending, stale registration from a deleted build — that the app should ask
    /// the daemon rather than trust the status.
    nonisolated static func isReachable() -> Bool {
        let version: String? = withProxy(timeout: 2) { proxy, done in
            proxy.helperVersion { done($0) }
        }
        return version != nil
    }
}
