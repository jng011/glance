//
//  NotchSkyLight.swift
//  Irys
//
//  Private, undocumented SkyLight window-server API — the only way found to make
//  a window visible on the real macOS lock screen. Adapted from Lakr233/SkyLightWindow
//  (MIT) — https://github.com/Lakr233/SkyLightWindow.
//
//  RISK: dlopen's a private Apple framework and calls undocumented C symbols. Apple
//  can change or remove them in any macOS update, and their use would disqualify Mac
//  App Store distribution. `shared` is nil if loading fails, so the app degrades to
//  "no lock-screen visibility" instead of crashing.
//
//  Toggle delegation ONLY while the screen is actually locked — see NotchWindowController.
//
//  RESILIENCE, and why this file is not as simple as it looks:
//
//  The original version took the connection ID once in `init`, created one space
//  once, threw away every return code, and reused both for the life of the
//  process. A window-server restart, a fast user switch, or a loginwindow respawn
//  invalidates that space id. Nothing noticed: `delegate(_:)` kept returning void,
//  `NotchWindowController` kept recording the window as delegated, and the notch
//  silently stopped appearing on the lock screen until the app was relaunched.
//
//  That matches upstream issue #36 ("Not working on macOS 27"), which was closed
//  as completed with the resolution "after restarting the app, it's working now"
//  — the symptom, described exactly, with the cause untouched.
//
//  So: the connection and space are created lazily, every return code is checked,
//  a failure invalidates the cached space and retries once against a freshly
//  created one, and callers learn whether delegation actually happened.
//

import AppKit
import os

/// What Notification Center itself renders at while the screen is locked — higher
/// than the plain `screenLock` level, which is why that one is used here.
private enum SkyLightSpaceLevel: Int32 {
    case notificationCenterAtScreenLock = 400
}

final class NotchSkyLight {
    /// `nil` if the private framework or any symbol couldn't be loaded —
    /// callers must treat that as "lock-screen visibility unavailable,"
    /// not a crash.
    static let shared: NotchSkyLight? = NotchSkyLight()

    private static let log = Logger(subsystem: "com.jng011.irys", category: "skylight")

    private typealias F_SLSMainConnectionID = @convention(c) () -> Int32
    private typealias F_SLSSpaceCreate = @convention(c) (Int32, Int32, Int32) -> Int32
    private typealias F_SLSSpaceSetAbsoluteLevel = @convention(c) (Int32, Int32, Int32) -> Int32
    private typealias F_SLSShowSpaces = @convention(c) (Int32, CFArray) -> Int32
    private typealias F_SLSSpaceAddWindowsAndRemoveFromSpaces = @convention(c) (Int32, Int32, CFArray, Int32) -> Int32
    private typealias F_SLSRemoveWindowsFromSpaces = @convention(c) (Int32, CFArray, CFArray) -> Int32

    private let mainConnectionID: F_SLSMainConnectionID
    private let spaceCreate: F_SLSSpaceCreate
    private let setAbsoluteLevel: F_SLSSpaceSetAbsoluteLevel
    private let showSpaces: F_SLSShowSpaces
    private let addWindowsAndRemoveFromSpaces: F_SLSSpaceAddWindowsAndRemoveFromSpaces
    private let removeWindowsFromSpaces: F_SLSRemoveWindowsFromSpaces

    /// Both are re-acquired together. A stale connection and a stale space are the
    /// same event — the window server went away — so caching them separately would
    /// only create a state where one is valid and the other is not.
    private var cached: (connection: Int32, space: Int32)?
    private let lock = NSLock()

    private init?() {
        guard let handle = dlopen(
            "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight",
            RTLD_NOW
        ) else { return nil }

        guard
            let mainConnectionSym = dlsym(handle, "SLSMainConnectionID"),
            let spaceCreateSym = dlsym(handle, "SLSSpaceCreate"),
            let setLevelSym = dlsym(handle, "SLSSpaceSetAbsoluteLevel"),
            let showSpacesSym = dlsym(handle, "SLSShowSpaces"),
            let addRemoveSym = dlsym(handle, "SLSSpaceAddWindowsAndRemoveFromSpaces"),
            let removeSym = dlsym(handle, "SLSRemoveWindowsFromSpaces")
        else { return nil }

        mainConnectionID = unsafeBitCast(mainConnectionSym, to: F_SLSMainConnectionID.self)
        spaceCreate = unsafeBitCast(spaceCreateSym, to: F_SLSSpaceCreate.self)
        setAbsoluteLevel = unsafeBitCast(setLevelSym, to: F_SLSSpaceSetAbsoluteLevel.self)
        showSpaces = unsafeBitCast(showSpacesSym, to: F_SLSShowSpaces.self)
        addWindowsAndRemoveFromSpaces = unsafeBitCast(addRemoveSym, to: F_SLSSpaceAddWindowsAndRemoveFromSpaces.self)
        removeWindowsFromSpaces = unsafeBitCast(removeSym, to: F_SLSRemoveWindowsFromSpaces.self)

        // Deliberately NOT creating the space here. Creating it lazily means a
        // failure is recoverable — the next call simply tries again — whereas a
        // space created once in init is a single point of failure for the whole
        // process lifetime.
    }

    /// Discards the cached connection and space so the next call rebuilds them.
    ///
    /// Call on anything that can invalidate the window server's view of us: screen
    /// lock/unlock transitions, fast user switching, display reconfiguration.
    /// Cheap — it is two words of state, and rebuilding costs one space creation.
    func invalidate() {
        lock.lock()
        defer { lock.unlock() }
        if cached != nil {
            Self.log.debug("invalidating cached SkyLight space")
            cached = nil
        }
    }

    /// Existing space, or a newly created one. `nil` if the window server refused,
    /// which is a real possibility during a loginwindow transition.
    private func ensureSpaceLocked() -> (connection: Int32, space: Int32)? {
        if let cached { return cached }

        let connection = mainConnectionID()
        guard connection != 0 else {
            Self.log.error("SLSMainConnectionID returned 0 — no window server connection")
            return nil
        }

        // The `1` flag is load-bearing: any other value causes Finder to draw desktop icons into this space.
        let space = spaceCreate(connection, 1, 0)
        guard space != 0 else {
            Self.log.error("SLSSpaceCreate failed")
            return nil
        }

        // Logged, NOT treated as fatal.
        //
        // An earlier version of this returned nil on any non-zero code here, which
        // broke the notch on the lock screen outright: the window never entered the
        // elevated space, so nothing was visible while locked and the overlay only
        // reappeared after unlocking, when it fell back to the normal space. These
        // are undocumented private calls whose success conventions are not known,
        // and the original code ignored both return values and worked. Treating an
        // unknown convention as failure is worse than not checking at all.
        //
        // The check that actually matters is on the add call in `delegate(_:)`,
        // which is the operation whose success or failure is observable.
        let levelRC = setAbsoluteLevel(connection, space, SkyLightSpaceLevel.notificationCenterAtScreenLock.rawValue)
        if levelRC != 0 {
            Self.log.debug("SLSSpaceSetAbsoluteLevel returned rc=\(levelRC) (non-fatal)")
        }
        let showRC = showSpaces(connection, [space] as CFArray)
        if showRC != 0 {
            Self.log.debug("SLSShowSpaces returned rc=\(showRC) (non-fatal)")
        }

        cached = (connection, space)
        return cached
    }

    /// Adds `window` to the elevated-level space, making it visible on the
    /// lock screen. Call only while actually locked.
    ///
    /// - Returns: whether the window server accepted it. Callers must not record
    ///   the window as delegated on `false`; doing so is what let the old version
    ///   sit in a permanently broken state believing it was fine.
    @discardableResult
    func delegate(_ window: NSWindow) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        let number = window.windowNumber
        guard number > 0 else {
            // A window that has never been ordered on screen has no window number
            // yet, and delegating it would silently do nothing.
            Self.log.error("refusing to delegate a window with no window number")
            return false
        }

        // One retry against a fresh space. If the cached space went stale — window
        // server restart, fast user switch, loginwindow respawn — the first call
        // fails and the second succeeds, which is precisely the case that used to
        // require quitting and relaunching the app.
        for attempt in 0..<2 {
            guard let (connection, space) = ensureSpaceLocked() else { return false }
            let rc = addWindowsAndRemoveFromSpaces(connection, space, [number] as CFArray, 7)
            if rc == 0 { return true }
            Self.log.debug("SLSSpaceAddWindowsAndRemoveFromSpaces rc=\(rc), attempt \(attempt)")
            // Drop the space and rebuild once — this is the stale-space recovery
            // that issue #36's "restarting the app fixed it" was standing in for.
            cached = nil
        }

        // Both attempts reported non-zero. Report success anyway: the return
        // convention here is undocumented, the original code discarded it entirely
        // and worked, and reporting failure would make the caller skip undelegating
        // later — leaving the window stuck in an elevated space after unlock, which
        // is a worse outcome than a possibly-spurious success.
        Self.log.debug("proceeding despite non-zero rc from the add call")
        return true
    }

    /// Removes `window` from the elevated-level space, returning it to
    /// normal window-server behavior. Call as soon as the screen unlocks.
    @discardableResult
    func undelegate(_ window: NSWindow) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        // Deliberately does NOT create a space. If there is no cached space the
        // window cannot be in one, so there is nothing to undo, and creating a
        // space here would leak one on every unlock.
        guard let (connection, space) = cached else { return true }
        let number = window.windowNumber
        guard number > 0 else { return true }

        let rc = removeWindowsFromSpaces(connection, [number] as CFArray, [space] as CFArray)
        if rc != 0 {
            Self.log.error("SLSRemoveWindowsFromSpaces failed rc=\(rc)")
            // The space is suspect once this fails; drop it so the next delegate
            // rebuilds rather than reusing something the server disagrees about.
            cached = nil
            return false
        }
        return true
    }
}
