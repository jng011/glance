//
//  IrysHelperProtocol.swift
//  Shared by the Irys app and the IrysHelper privileged daemon.
//
//  This file is compiled into BOTH targets. Keep it free of anything that only
//  one side can import — a mismatch here is a runtime XPC failure, not a build
//  error, and it surfaces as "the helper never answers."
//

import Foundation

/// Mach service the daemon vends. Must match `MachServices` in the launchd plist
/// and the name the app connects to, exactly.
public let irysHelperMachServiceName = "com.jng011.irys.helper"

/// launchd label. Must match the plist filename in Contents/Library/LaunchDaemons.
public let irysHelperLabel = "com.jng011.irys.helper"

/// What the app is allowed to ask the root daemon to do.
///
/// Deliberately tiny. This runs as root and hands back material that decrypts the
/// user's login password, so every method here is a thing an attacker would like
/// to call. Nothing is added to this protocol that the app can do for itself.
@objc public protocol IrysHelperProtocol {
    /// Version handshake, so a stale daemon left behind by an older install is
    /// detected rather than silently answering with different semantics.
    func helperVersion(reply: @escaping (String) -> Void)

    /// Hands back the stored session key, or nil if none is stored.
    ///
    /// No user presence check: the entire point is that the app can get this at
    /// the lock screen, where no Touch ID prompt can be shown. The access control
    /// is the caller's code signature, verified in the listener delegate — see
    /// `IrysHelperListenerDelegate`.
    func sessionKey(reply: @escaping (Data?) -> Void)

    /// Stores (or with nil, clears) the session key.
    func setSessionKey(_ key: Data?, reply: @escaping (Bool) -> Void)
}
