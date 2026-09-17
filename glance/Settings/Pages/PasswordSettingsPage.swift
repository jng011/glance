//
//  PasswordSettingsPage.swift
//  glance
//

import SwiftUI

struct PasswordSettingsPage: View {
    @Bindable var pocController: POCController
    @Bindable private var settings = GlanceSettings.shared

    @State private var isUnlocking = false
    @State private var sessionError: String?
    @State private var statusMessage: String?

    /// Read from `POCController`, not a local copy — `SessionAutoLocker` can
    /// lock the session from outside this view.
    private var isSessionUnlocked: Bool { pocController.isSessionUnlocked }

    /// "No password stored" takes priority over lock state entirely, so
    /// removal doesn't fall back to an "unlock session" prompt for a
    /// session that no longer protects anything.
    private enum PageState: Equatable {
        case noPassword
        case locked
        case unlocked
    }

    private var pageState: PageState {
        guard pocController.hasStoredPassword else { return .noPassword }
        return isSessionUnlocked ? .unlocked : .locked
    }

    var body: some View {
        ZStack(alignment: .top) {
            noPasswordState
                .opacity(pageState == .noPassword ? 1 : 0)
                // Hidden from hit-testing and accessibility while faded out.
                .allowsHitTesting(pageState == .noPassword)
                .accessibilityHidden(pageState != .noPassword)

            lockedState
                .opacity(pageState == .locked ? 1 : 0)
                .allowsHitTesting(pageState == .locked)
                .accessibilityHidden(pageState != .locked)

            unlockedState
                .opacity(pageState == .unlocked ? 1 : 0)
                .allowsHitTesting(pageState == .unlocked)
                .accessibilityHidden(pageState != .unlocked)
        }
        .animation(SettingsMetrics.stateTransitionAnimation, value: pageState)
        .onAppear { pocController.refreshCredentialStatus() }
        // The onboarding password step runs in the notch, outside this
        // view's hierarchy, so nothing else prompts a re-check once it closes.
        .onChange(of: NotchOverlayController.shared.phase) { _, newPhase in
            guard newPhase == .closed else { return }
            pocController.refreshCredentialStatus()
            FaceEnrollmentStore.shared.reloadIfUnlocked()
        }
    }

    // MARK: - No password stored

    private var noPasswordState: some View {
        SettingsEmptyStateView(
            icon: "lock.fill",
            message: "Set up a password",
            buttonTitle: "Set password",
            caption: statusMessage,
            action: { OnboardingController.startPasswordOnly() }
        )
    }

    // MARK: - Locked

    private var lockedState: some View {
        SettingsEmptyStateView(
            icon: "lock.fill",
            message: "Session locked",
            buttonTitle: isUnlocking ? "Authenticating…" : "Unlock session",
            isButtonEnabled: !isUnlocking,
            caption: sessionError,
            action: unlock
        )
    }

    // MARK: - Unlocked

    private var unlockedState: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.rowSpacing) {
            SettingsGroup {
                SettingsRowContent(title: "Password encrypted") {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(SettingsMetrics.textSecondary)
                }

                SettingsGroupDivider()

                StayUnlockedRow()

                SettingsGroupDivider()

                HelperInstallRow()

                SettingsGroupDivider()

                SettingsSteppedSliderRowContent(
                    title: "Auto lock session",
                    valueLabel: settings.autoLockInterval.title,
                    index: Binding(
                        get: { settings.autoLockInterval.sliderIndex },
                        set: { settings.autoLockInterval = .from(sliderIndex: $0) }
                    ),
                    stopCount: AutoLockInterval.allCases.count
                )
                // The idle timer has no effect while the session never locks, so
                // showing it as live would be a lie.
                .disabled(settings.staysUnlockedUntilRestart)
                .opacity(settings.staysUnlockedUntilRestart ? 0.4 : 1)

                SettingsGroupDivider()

                SettingsRowContent(title: "Change password") {
                    SettingsPrimaryButton(title: "Change", compact: true) {
                        OnboardingController.startPasswordOnly()
                    }
                }

                SettingsGroupDivider()

                SettingsRowContent(title: "Remove password") {
                    HoldToConfirmButton(title: "Remove", action: removePassword)
                }
            }

            if let statusMessage {
                SettingsCaption(text: statusMessage)
            }
        }
    }

    // MARK: - Actions

    private func unlock() {
        isUnlocking = true
        sessionError = nil
        Task {
            await pocController.unlockSession()
            sessionError = pocController.sessionError
            // Face store is encrypted under the same session key, so reload
            // it now rather than leaving Your Face stuck showing "locked".
            FaceEnrollmentStore.shared.reloadIfUnlocked()
            isUnlocking = false
        }
    }

    /// Face samples must be deleted before the password/session key —
    /// `deletePassword()` clears the cached session key, and deleting the
    /// face store requires an unlocked session.
    private func removePassword() {
        do {
            FaceEnrollmentStore.shared.deleteAll()
            try SecureCredentialManager.deletePassword()
            pocController.refreshCredentialStatus()
            statusMessage = "Password and face enrollment removed."
        } catch {
            statusMessage = "Couldn't remove: \(error.localizedDescription)"
        }
    }
}

/// Toggle for `GlanceSettings.staysUnlockedUntilRestart`.
///
/// Separate view because flipping it is not a settings write — it re-stores the
/// session key in the Keychain with or without its Touch ID gate, which can
/// prompt and can fail, and a plain `Binding` has nowhere to put either.
private struct StayUnlockedRow: View {
    @State private var settings = GlanceSettings.shared
    @State private var isWorking = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsRowContent(
                title: "Stay unlocked until restart",
                subtitle: "Ask for Touch ID once when you log in, instead of every time. The trade-off: other apps on your Mac could read your saved password.",
                subtitleMaxWidth: SettingsMetrics.rowSubtitleMaxWidth
            ) {
                if isWorking {
                    ProgressView().controlSize(.small)
                } else {
                    GlanceToggle(isOn: Binding(
                        get: { settings.staysUnlockedUntilRestart },
                        set: { apply($0) }
                    ))
                }
            }

            if let error {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(GlanceTheme.statusDenied)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, SettingsMetrics.rowHorizontalInset)
                    .padding(.bottom, 8)
            }
        }
    }

    /// Migrates the key first and only records the setting if that succeeded.
    ///
    /// Writing the flag first would leave the app believing the key is ungated
    /// when it is still gated — every unlock would then fall back to a Touch ID
    /// prompt the user was told they had turned off, with nothing explaining why.
    private func apply(_ enabled: Bool) {
        isWorking = true
        error = nil
        let reason = enabled
            ? "Authenticate to keep Irys unlocked until restart"
            : "Authenticate to re-protect the Irys session with Touch ID"

        Task.detached {
            do {
                try SecureCredentialManager.setStaysUnlocked(enabled, reason: reason)
                await MainActor.run {
                    settings.staysUnlockedUntilRestart = enabled
                    isWorking = false
                }
            } catch {
                await MainActor.run {
                    self.error = error.localizedDescription
                    isWorking = false
                }
            }
        }
    }
}

/// Install / status row for the privileged background helper.
///
/// Separate from the "Stay unlocked" toggle because the two are independent: the
/// toggle asks for the behaviour, this decides how well the key is protected
/// while providing it. Without the helper the key sits ungated in the Keychain,
/// readable by anything running as this user; with it, the key lives in
/// root-owned storage that only a signature-verified caller can read.
///
/// One admin authentication, once. macOS verifies that password itself and
/// discards it — the app never sees it.
private struct HelperInstallRow: View {
    @State private var client = HelperClient.shared
    @State private var isWorking = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsRowContent(
                title: "Background helper",
                subtitle: subtitle,
                subtitleMaxWidth: SettingsMetrics.rowSubtitleMaxWidth
            ) {
                trailing
            }

            if let error {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(GlanceTheme.statusDenied)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, SettingsMetrics.rowHorizontalInset)
                    .padding(.bottom, 8)
            }
        }
        // Approval happens in System Settings, outside this app, so the state here
        // is stale the moment the user leaves. Re-reading on activation is what
        // makes the row correct when they come back.
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification
        )) { _ in
            client.refresh()
        }
    }

    private var subtitle: String {
        switch client.availability {
        case .enabled:
            return "On. Your saved password is kept somewhere only Irys can reach, so other apps can't read it."
        case .requiresApproval:
            return "Almost there — macOS needs you to switch it on in Login Items."
        case .notRegistered:
            return "Recommended if you turn on \"Stay unlocked\". Keeps your saved password out of reach of other apps."
        case .unavailable(let reason):
            return reason
        }
    }

    @ViewBuilder
    private var trailing: some View {
        if isWorking {
            ProgressView().controlSize(.small)
        } else {
            switch client.availability {
            case .enabled:
                SettingsPrimaryButton(title: "Remove", compact: true) { remove() }
            case .requiresApproval:
                SettingsPrimaryButton(title: "Open Settings", compact: true) {
                    client.openLoginItemsSettings()
                }
            case .notRegistered:
                SettingsPrimaryButton(title: "Install", compact: true) { install() }
            case .unavailable:
                EmptyView()
            }
        }
    }

    private func install() {
        isWorking = true
        error = nil
        do {
            try client.register()
        } catch {
            self.error = error.localizedDescription
        }
        isWorking = false
    }

    /// Removing the helper deliberately does NOT re-gate the Keychain key here.
    ///
    /// That is the "Stay unlocked" toggle's job, and doing it silently from this
    /// row would mean a user who removed a background item suddenly started being
    /// asked for Touch ID again with nothing connecting the two.
    private func remove() {
        isWorking = true
        error = nil
        do {
            try client.unregister()
        } catch {
            self.error = error.localizedDescription
        }
        isWorking = false
    }
}
