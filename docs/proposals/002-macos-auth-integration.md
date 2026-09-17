# 002 — Can Irys stop storing the user's password?

Research target: macOS 27.0 (build 26A428), Apple Silicon, Xcode 27.0 (SDK `MacOSX27.0.sdk`).
Everything below is marked **VERIFIED** (read out of Apple documentation, a real header or binary
on this machine, or the output of a command run here) or **UNVERIFIED** (plausible, inferred, or
sourced from a third party). An invented API is worse than an admitted gap.

Findings 1–4 were established by the main session and are preserved verbatim. Findings 5–9 close
the open questions that were left at the bottom of the earlier draft.

## The problem

`glance/KeystrokeInjector.swift` types the user's login password into the lock screen with
synthesised CGEvents. That is why `SecureCredentialManager` has to store the password in
*retrievable* form at all — a password you must replay cannot be stored as a one-way hash. It is
the worst property of the design, and every other security improvement is downstream of it.

The project's standing assumption: "macOS has no API that lets a third-party app authorize a
login." This document tests that.

---

# Question 1 — Authorization plugins / SecurityAgent

## Finding 1 — screen unlock is NOT mechanism-based by default (VERIFIED)

This is the one that matters, because screen unlock is what Irys actually does.

```
$ security authorizationdb read system.login.screensaver
    class   = rule
    rule    = [ use-login-window-ui ]
    comment = The owner or any administrator can unlock the screensaver,
              set rule to "authenticate-session-owner-or-admin" to enable SecurityAgent.
```

`class` is **`rule`**, not `evaluate-mechanisms`. There is no mechanism array, so there is no
chain for a third-party `SecurityAgentPlugin` to be inserted into. The right delegates to
`use-login-window-ui` — loginwindow's own UI handles it.

Apple's own comment is explicit that SecurityAgent is not even in the path by default; you would
have to *change the rule* to `authenticate-session-owner-or-admin` to bring SecurityAgent in.
That is a system-wide modification to the authorization database, requiring root, altering how
every screen unlock on the machine is evaluated, and it is not something an app can reasonably
ask a user to accept.

> **Correction from Finding 5 below:** the original conclusion here — "the obvious 'just write an
> authorization plugin' path does not apply to screen unlock" — is too strong. It does apply; it
> is just gated behind rewriting this right, and the cost of doing so is that the machine loses
> Touch ID unlock and the modern lock screen. See Finding 5.

For completeness, `use-login-window-ui` resolves to an ordinary rule definition in
`/System/Library/Security/authorization.plist` — no mechanisms of its own (VERIFIED, read on this
machine):

```python
'use-login-window-ui': {'allow-root': False, 'class': 'user', 'group': 'admin',
                        'session-owner': True, 'shared': False,
                        'comment': 'Authenticate either as the owner or as an administrator.'}
```

Note that it is byte-for-byte the same definition as `authenticate-session-owner-or-admin`. The
*name* is the signal, not the contents — see Finding 5.

## Finding 2 — the login window IS mechanism-based, and mostly useless to us (VERIFIED)

```
$ security authorizationdb read system.login.console
    class      = evaluate-mechanisms
    mechanisms = builtin:prelogin
                 builtin:policy-banner
                 loginwindow:login
                 builtin:login-begin
                 builtin:reset-password,privileged
                 loginwindow:FDESupport,privileged
                 builtin:forward-login,privileged
                 builtin:auto-login,privileged
                 builtin:authenticate,privileged
                 builtin:login-success
                 loginwindow:success
                 HomeDirMechanism:login,privileged
                 HomeDirMechanism:status
                 MCXMechanism:login
                 CryptoTokenKit:login          <-- note this
                 loginwindow:done
```

This is a real mechanism chain, and it is where enterprise SSO tools insert themselves. But it
governs **cold login** — before any user session exists. Irys cannot run there: no user session
means no camera access, no Keychain, no loaded CoreML model. So even though this surface is
extensible, it is the wrong surface for this app.

`/Library/Security/SecurityAgentPlugins/` exists, is root-owned, and is **empty** on this machine
— confirming it is the third-party install location, and that nothing here uses it today.

`/System/Library/Security/SecurityAgentPlugins/` **does not exist** on macOS 27.0 (VERIFIED —
`ls` returns "No such file or directory"). Apple's own mechanisms (`builtin:`, `loginwindow:`,
`CryptoTokenKit:`, `HomeDirMechanism:`, `MCXMechanism:`) are not loose bundles on disk any more.
Only the third-party directory remains.

## Finding 5 — what `use-login-window-ui` actually does, and the real cost of replacing it (VERIFIED)

This was open question #2 in the earlier draft. It is now closed, from an Apple DTS statement.

Quinn "The Eskimo!" (Apple Developer Technical Support), on
[Display Authorization plugin at screensaver unlock](https://developer.apple.com/forums/thread/110667):

> "The `use-login-window-ui` mechanism causes the system to run the fancy new code path with Touch
> ID and so on, one that's not compatible with third-party authorisation plug-ins. If you remove
> that then you fall back to a legacy code path that is compatible with third-party authorisation
> plug-ins, but you lose all the nice new features."

And, from the same engineer (January 2021):

> "Modern systems prevent third-party code, including authorisation plug-ins, from showing UI on
> top of the lock screen. The only way to present UI in that context is to build an authorisation
> plug-in based on `SFAuthorizationPluginView`."
>
> "Authorisation plug-ins are not able to use Touch ID."
>
> "Neither of these is considered a bug."

So `use-login-window-ui` is **not** an internal mechanism chain with a hook in it. It is a
sentinel: loginwindow reads the rule name and, on seeing it, takes an entirely different
(non-plugin) code path. It is opaque by design, and there is no documented or observable hook
inside it. **VERIFIED.**

**But the rule can be replaced, and third-party plugins do still work on macOS 26/27.** On
[SFAuthorizationPluginView and macOS Tahoe](https://developer.apple.com/forums/thread/798550)
a developer reports their own mechanism plus a third-party one (HYPR, a commercial passwordless
vendor) both running and both drawing UI at screen unlock on macOS 26; Quinn's reply — "I think
this is just how macOS 15 and 26 work" — treats plugin participation at unlock as normal, and only
the UI-stacking oddity as a bug worth filing. So the surface is alive, not deprecated.
**VERIFIED that it works on 26; UNVERIFIED on 27.0 specifically — nobody has published a 27 report
and I did not modify this machine's authorization database to test it.**

### Can a plugin *grant* the right without a password existing anywhere?

Yes. From `AuthorizationPlugin.h` in the macOS 27.0 SDK on this machine (VERIFIED):

```c
typedef CF_CLOSED_ENUM(UInt32, AuthorizationResult) {
    kAuthorizationResultAllow,     // "the operation succeeded and authorization should be
                                   //  granted as far as this mechanism is concerned"
    kAuthorizationResultDeny,
    kAuthorizationResultUndefined,
    kAuthorizationResultUserCanceled,
};
```

A mechanism calls `SetResult(engine, kAuthorizationResultAllow)` and that is the whole contract.
Nothing requires it to produce a secret. The password-shaped context keys
(`kAuthorizationEnvironmentUsername` / `kAuthorizationEnvironmentPassword`, from
`AuthorizationTags.h`, VERIFIED) exist so that a mechanism *can* hand a password downstream to
`builtin:authenticate,privileged` — but if you replace the whole chain, nothing downstream is
asking for one.

Crucially, for **screensaver** unlock this is enough on its own: the session is already running,
the login keychain is already unlocked, FileVault is already unlocked. There is no secret that the
unlock needs to derive. (For **cold login** the opposite is true — loginwindow needs the password
to unlock the login keychain and the FileVault-protected user record, which is why enterprise
plugins like Jamf Connect and XCreds still collect and forward a password.)

### The deployment burden, concretely

| Requirement | Status |
|---|---|
| Bundle in `/Library/Security/SecurityAgentPlugins/` | root write. Directory is **not** SIP-restricted (VERIFIED — `ls -ldO` shows no `restricted` flag) |
| Rewrite `system.login.screensaver` | root, or admin authentication: the governing right `config.modify.` is `['is-root', 'authenticate-admin']` (VERIFIED from `authorization.plist`) |
| SIP | **Does not need to be disabled.** Neither `/Library/Security` nor `/etc/pam.d` is restricted (VERIFIED). `/usr/lib/pam` *is* restricted |
| Entitlement | None required for the plugin bundle itself (UNVERIFIED — inferred from the fact that XCreds and Jamf Connect ship ordinary Developer ID bundles) |
| Installer | A signed, notarized `.pkg` with a postinstall script. This is exactly what [XCreds](https://twocanoes.com/knowledge-base/xcreds-admin-guide/) does: `xcreds_login.sh -i` drops `XCredsLoginPlugin.bundle` into `/Library/Security/SecurityAgentPlugins` and rewrites the authorizationdb |
| UI on the lock screen | Only via `SFAuthorizationPluginView` (present and non-deprecated in `SecurityInterface.framework` on this machine; every method is `API_AVAILABLE(macos(10.5))`, none carry `API_DEPRECATED` — VERIFIED) |

### What it costs the user

1. **Touch ID unlock stops working** for the whole machine, for every user, because the modern
   code path is gone. This is a catastrophic regression for a Mac with a Touch ID key, and it is
   not something Irys can scope to itself.
2. The lock screen reverts to the legacy SecurityAgent UI.
3. A system-wide authorization database rewrite, surviving uninstall unless carefully reverted.
4. It is a `.pkg` with root, not a drag-to-Applications app.

**Finding: an authorization plugin CAN eliminate the stored password for screen unlock, and the
mechanism is supported and still functional on macOS 26. But the price is the machine's Touch ID
unlock and the modern lock screen, which is not a trade a consumer app can ask for.**
**VERIFIED (mechanism and cost) / UNVERIFIED (behaviour on 27.0 specifically).**

Sources:
[Apple DevForums 110667](https://developer.apple.com/forums/thread/110667),
[798550](https://developer.apple.com/forums/thread/798550),
[819454](https://developer.apple.com/forums/thread/819454),
[Elliot Jordan — Managing login mechanisms in the macOS authorization database](https://www.elliotjordan.com/posts/macos-authdb-mechs/),
[XCreds Admin Guide](https://twocanoes.com/knowledge-base/xcreds-admin-guide/),
[Jamf Connect — Editing the macOS loginwindow application](https://docs.jamf.com/jamf-connect/2.1.2/administrator-guide/Editing_the_macOS_loginwindow_application.html).

---

# Question 2 — PAM

## Finding 3 — `sudo` is genuinely extensible, and this is a real feature (VERIFIED)

```
$ cat /etc/pam.d/sudo
    auth  include     sudo_local
    auth  sufficient  pam_smartcard.so
    auth  required    pam_opendirectory.so
```

The first line is the important one. `sudo_local` is Apple's **supported, documented** extension
point — it is exactly where users are told to add `pam_tid.so` to enable Touch ID for `sudo`, and
it survives OS updates precisely because it is a separate file Apple does not overwrite.

A custom PAM module here is the same shape of thing `pam_tid.so` is. **"Authenticate `sudo` with
your face" is achievable, on a supported path, with no password stored.** PAM modules return
success/failure — they do not need to produce a secret.

On this machine `sudo_local` is already active (VERIFIED — the `pam_tid.so` line is uncommented,
and the file is dated later than the rest of `/etc/pam.d`):

```
$ cat /etc/pam.d/sudo_local
# sudo_local: local config file which survives system update and is included for sudo
# uncomment following line to enable Touch ID for sudo
auth       sufficient     pam_tid.so
```

`sudo` itself is still real sudo, not a rewrite: `Sudo version 1.9.17p2` (VERIFIED).

## Finding 4 — screensaver PAM is not the unlock path (VERIFIED)

```
$ cat /etc/pam.d/screensaver
    auth     optional  pam_krb5.so use_first_pass use_kcminit
    auth     required  pam_opendirectory.so use_first_pass nullok
    account  required  pam_opendirectory.so
    ...
```

Note what is **absent**: `pam_tid.so`. Touch ID unlocks the screen, but not through this file. So
`/etc/pam.d/screensaver` is not the lever for screen unlock either, and the `use_first_pass` flags
indicate this stack expects a password already collected by something upstream.

This corroborates Finding 1 from a second direction.

### Where Touch ID unlock actually lives

`/etc/pam.d/` on macOS 27.0 has a **family** of per-factor stacks (VERIFIED — full listing):

| File | Contents | What it is |
|---|---|---|
| `screensaver` | `pam_opendirectory.so use_first_pass` | password unlock |
| `screensaver_la` | `pam_localauthentication.so` + `pam_aks.so` | **Touch ID unlock** |
| `screensaver_aks` | `pam_aks.so` | Secure Enclave / AKS only |
| `screensaver_ctk` | `pam_smartcard.so use_first_pass` | **smart card unlock** |
| `screensaver_new` | `pam_opendirectory.so use_first_pass` | |
| `authorization` / `_la` / `_lacont` / `_aks` / `_ctk` | same pattern | authorization dialogs |

`authorization_lacont` carries the flag `continuityunlock` — that is Apple Watch unlock. So the
system picks a *stack per factor* and the factor set is fixed by which `pam_*.so` Apple ships.
There is no `screensaver_<thirdparty>` slot to claim.

## Finding 6 — which processes will actually load a third-party PAM module (VERIFIED)

This is the part that most internet advice gets wrong. The gate is not your code signature; it is
the code signature of the *Apple process doing the loading*.

Quinn, on
[The notarized custom PAM module cannot function properly after unlock from screensaver](https://developer.apple.com/forums/thread/772227):

> "Could this issue also be related to a code signing configuration that needs adjustment? On your
> part? **No.**"
>
> "`authorizationhost` … is signed with `com.apple.private.security.clear-library-validation`"
>
> "`coreauthd` … has no library-validation exception"
>
> "you can't resolve this problem by adjusting your code signature. **The gating factor here is
> the code signature of the Apple code.**"
>
> "it's possible that you can avoid this issue by switching from a PAM module to an authorisation
> plug-in. Authorisation plug-ins are loaded by various helper processes that expect to disable
> library validation."

I confirmed both halves of that on this machine (VERIFIED):

```
$ codesign -d --entitlements - .../Security.framework/.../authorizationhost
	[Key] com.apple.private.security.clear-library-validation      <-- present

$ codesign -d --entitlements - .../LocalAuthentication.framework/Support/coreauthd
	(no clear-library-validation entitlement)
```

The reported failure mode, verbatim from that thread:

```
Library Validation failed: Rejecting '/usr/local/lib/pam/pam_custom.so'
(Team ID: none, platform: no) for process 'coreauthd(653)' (Team ID: N/A, platform: yes)
```

### Placement and SIP

- `/usr/lib/pam` is **SIP-restricted** (VERIFIED — `ls -laO` shows `restricted,compressed`). You
  cannot add a module there, even as root, without disabling SIP.
- `/etc/pam.d` is **not** restricted (VERIFIED — no flag). Root can edit it.
- openpam accepts an absolute path in the config line, so the module can live in
  `/Library/Application Support/Irys/` or `/usr/local/lib/pam/`. (UNVERIFIED by direct test — I did
  not modify `/etc/pam.d`; but the `coreauthd` error above shows the system loading a module from
  `/usr/local/lib/pam/`, which is direct evidence that absolute paths outside `/usr/lib/pam` work.)

### macOS 26 tightened this further

A Homebrew discussion opened 8 Dec 2025 reports `google-authenticator-libpam` breaking with
Apple's `sshd` on macOS 26.1:

```
Library Validation failed: Rejecting '/opt/homebrew/Cellar/.../pam_google_authenticator.so'
... mapping process is a platform binary, but mapped file is not
```

i.e. Apple platform binaries now refuse to load non-platform libraries unless they carry the
`clear-library-validation` exception. The thread's own August 2026 follow-up notes that `sudo`
*may* have that exception but that this is **untested**.
([Homebrew discussion 6597](https://github.com/orgs/Homebrew/discussions/6597)) — **UNVERIFIED as
it applies to `sudo`.**

I could not settle it here: `/usr/bin/sudo` is mode `-r-s--x--x root:wheel restricted`, so
`codesign -d --entitlements -` returns "Permission denied" without root, and this task is
read-only (VERIFIED that the check is blocked, not that the answer is either way).

**This is the single highest-value five-minute experiment left in this document.** Run as the user:

```bash
sudo codesign -d --entitlements - /usr/bin/sudo 2>&1 | grep -i library-validation
```

If `com.apple.private.security.clear-library-validation` is present, the `sudo_local` feature is
green. If it is absent, the feature is dead on macOS 26+ and the whole PAM section collapses to
"nothing to build here".

### The shape of the module

The coordinator's guess is right, and it is forced by three separate constraints:

1. **A PAM module is a dylib loaded into `sudo`**, a setuid-root, short-lived, non-GUI process. It
   must not link CoreML, Vision, AVFoundation, or SwiftUI, and it must not try to open the camera
   — `sudo` has no TCC identity of its own for that.
2. So the module is a **small C shim**: `pam_sm_authenticate()` connects to a long-running Irys
   agent in the user's GUI session over XPC (or a UNIX domain socket in the user's container),
   asks "has this user's face matched within the last N seconds, and will you re-scan now?",
   blocks briefly, and returns `PAM_SUCCESS` / `PAM_AUTH_ERR`.
3. **The session-attachment problem is real and already solved by someone else.** `sudo` run inside
   tmux/screen is detached from the GUI session, which is why `pam_tid.so` fails there and why
   [`pam_reattach`](https://github.com/fabianishere/pam_reattach) exists and is placed *before*
   `pam_tid.so` in `sudo_local`. Irys's shim would hit the same wall reaching a GUI-session agent.
   `pam_reattach` is MIT-ish, builds universal arm64+x86_64 with CMake, and is the reference
   implementation to read. (UNVERIFIED that it currently works on macOS 27.0.)

Other real-world precedents to copy from:
[pam-watchid](https://github.com/mostpinkest/pam-watchid),
[pam_wtid](https://github.com/inickt/pam_wtid). Both are third-party modules installed via
`sudo_local`; both needed Apple-Silicon-aware forks.

### Installation burden for the PAM route

| Requirement | Status |
|---|---|
| Root | Yes — to write `/etc/pam.d/sudo_local` and install the `.so` |
| SIP disable | **No** (VERIFIED — `/etc/pam.d` unrestricted) |
| Architecture | arm64 (or universal) dylib. Nothing special beyond that (UNVERIFIED — no special flags found, but not tested) |
| Code signing | At minimum ad-hoc; the `coreauthd` rejection message literally says *"Code has to be at least ad-hoc signed."* Developer ID + notarization is the sane choice for a shipped app (VERIFIED that ad-hoc is the floor) |
| Package | A `.pkg` postinstall that appends one line to `sudo_local`, preserving the existing `pam_tid.so` line |
| Reversibility | Good. Uninstall = remove the line. Much cleaner than an authorizationdb rewrite |

**Finding: the `sudo_local` route is Apple's own supported extension point, needs root but not SIP
changes, has multiple third-party precedents, and requires no stored credential. Its one
unresolved blocker is whether macOS 26+ library validation still lets `sudo` load a non-platform
module. VERIFIED except for that blocker, which is UNVERIFIED and cheap to settle.**

---

# Question 3 — LocalAuthentication and the Secure Enclave

## Finding 7 — a third-party app can request a biometric factor, never provide one (VERIFIED)

The answer is definitive and negative, and it is verifiable by exhaustion rather than by finding a
sentence that says so.

**The complete LocalAuthentication header set on macOS 27.0** (VERIFIED — `ls` of
`LocalAuthentication.framework/Headers`): `LABase`, `LABiometryType`, `LACompanionType`,
`LAContext`, `LADomainState`, `LAEnvironment`, `LAEnvironmentMechanism`,
`LAEnvironmentMechanismBiometry`, `LAEnvironmentMechanismCompanion`,
`LAEnvironmentMechanismUserPassword`, `LAEnvironmentState`, `LAError`, `LAPersistedRight`,
`LAPrivateKey`, `LAPublicKey`, `LARequirement`, `LARight`, `LARightStore`, `LASecret`.

Every one of these is consumer-side. There is no `LAProvider`, no registration call, no delegate
an app can implement to answer an authentication request. `grep -i "provid|register|extension"`
across the whole header set returns only doc-comment prose ("the provided algorithm", "removes the
previously registered observer") — no API. **VERIFIED.**

**The factor list is a closed enum** (VERIFIED — `LAPublicDefines.h`):

```c
#define kLAPolicyDeviceOwnerAuthenticationWithBiometrics        1
#define kLAPolicyDeviceOwnerAuthentication                      2
#define kLAPolicyDeviceOwnerAuthenticationWithWatch             3   // -> ...WithCompanion
#define kLAPolicyDeviceOwnerAuthenticationWithBiometricsOrWatch 4   // -> ...OrCompanion
#define kLAPolicyDeviceOwnerAuthenticationWithWristDetection    5   // watchOS only
```

Touch ID, the account password, and an Apple Watch. There is no sixth slot, and `LAPolicy` is
`NS_ENUM`, not an extensible registry. Same story for `SecAccessControl` (VERIFIED —
`SecAccessControl.h`): `UserPresence`, `BiometryAny`, `BiometryCurrentSet`, `DevicePasscode`,
`Companion`, `Or`, `And`, `PrivateKeyUsage`, `ApplicationPassword`. All consumer-side; none of them
mean "whatever this app says".

**And the system's actual pluggable-authenticator extension points are enumerable** (VERIFIED —
`pluginkit -m -v -p com.apple.ctk-tokens`, and a scan of all 500 registered plug-ins on this
machine for anything auth-shaped). There are exactly two families:

- `com.apple.ctk-tokens` — CryptoTokenKit tokens (see Question 4 / Finding 8)
- Platform SSO / `AuthenticationServices` provider extensions (MDM-gated, see below)

There is no biometric-provider extension point. If one existed, `pluginkit` would list Apple's own
implementation of it, as it does for CTK.

### What the Secure Enclave can and cannot do for Irys

**It can gate key release, and that is all.** Concretely:

- `SecAccessControlCreateWithFlags(..., .userPresence, ...)` — as `KeychainManager.swift:117-126`
  already uses — means *the Secure Enclave will not release this key until it has itself seen a
  Touch ID match or the account password*. That is a genuine, hardware-enforced property. It is why
  the current two-tier design is not theatre: another process running as the user cannot silently
  read the session key.
- `kSecAttrTokenIDSecureEnclave` with `kSecAccessControlPrivateKeyUsage` gives you a P-256 key whose
  private half never leaves the SEP, and each signature can be gated the same way.

**It cannot do anything about Irys's own face match.** The trust boundary, stated plainly:

> Irys's face recognition runs in ordinary userspace, on frames delivered by AVFoundation to a
> process the user could patch, debug, or replace. The Secure Enclave has no channel by which
> `FaceRecognitionPipeline.bestMatch()` can tell it anything. There is no API to attest a
> userspace biometric decision to the SEP, and no API to make the SEP's key release conditional on
> one. When Irys decides "yes, that's him", the system's view of that event is exactly: **a normal
> program decided yes**.

The one thing hardware gating buys a design like Irys's is *unforgeable enrolment*: the SEP can
guarantee that the enrolled face templates and the stored credential were written by a session
that a human physically authorised with Touch ID, and cannot be read by a process that has not.
That is worth keeping. It is not the same as making the face match trustworthy.

It is worth being honest about the corollary: **a face match performed by a third-party app can
never be more than "a normal program decided yes", on any of the routes in this document.** An
authorization plugin calling `kAuthorizationResultAllow`, a PAM module returning `PAM_SUCCESS`, and
a CTK token agreeing to sign are all exactly that. What the routes buy is not *more trust in the
match* — it is *removing the need to keep a replayable password on disk*, which is a different and
smaller (but real) win.

Also worth noting, since it bounds the whole question: even Apple's own DTS told a developer that
putting facial recognition inside a system authentication flow is not achievable with current API.
Quinn, on [Custom TKTokenAuthOperation inside the CryptoTokenKit API](https://developer.apple.com/forums/thread/726164):

> "I don't think that goal is achievable given the current CTK API. I recommend that you file an
> enhancement request, making sure to describe your specific requirements in detail."

**Finding: a third-party app can only ever be a consumer of macOS biometrics, never a provider.
The Secure Enclave's contribution to Irys is limited to gating key release and binding enrolment to
a physical Touch ID event; it cannot attest to, strengthen, or vouch for a userspace face match.
VERIFIED.**

### The one exception, and why it does not apply

Platform SSO (macOS 13+) genuinely *is* a supported way for third-party code to authenticate the
login window and screen unlock with something other than the local password — including
`AuthenticationMethod = UserSecureEnclaveKey`, which authenticates with a hardware-bound key and no
password at all. Apple ships it as `AccessKey.appex` and `PlatformSSOToken.appex` (VERIFIED —
both registered under `com.apple.ctk-tokens` on this machine).

It is unusable for Irys because it requires an **MDM-delivered `com.apple.extensiblesso` profile**
and a real identity provider. A profile of that payload type cannot be installed by a downloaded
app on an unmanaged consumer Mac. ([Apple — Extensible Single Sign-on payload settings](https://support.apple.com/guide/deployment/extensible-single-sign-on-payload-settings-depfd9cdf845/web),
[Apple — Platform SSO for macOS](https://support.apple.com/guide/deployment/platform-sso-for-macos-dep7bbb05313/web),
[apple/device-management com.apple.extensiblesso.yaml](https://github.com/apple/device-management/blob/release/mdm/profiles/com.apple.extensiblesso.yaml)).
**VERIFIED that it exists and is MDM-gated; UNVERIFIED whether a locally-installed profile would be
accepted (I did not attempt it).**

---

# Question 4 — other prompts worth serving

## Finding 8 — CryptoTokenKit is the strongest remaining lead for password-free unlock (VERIFIED in parts)

This was open question #1 in the earlier draft and it deserves its own section, because it is the
only route found that is simultaneously (a) public API, (b) no stored password, (c) reaches screen
unlock, and (d) does not destroy Touch ID.

**Smart card authentication is supported at screen unlock.** Apple's deployment guide, on the
operations a smart card can perform (VERIFIED, quoted):

> "*Authentication:* LoginWindow, PKINIT, SSH, **Screensaver**, Safari, authorization dialogs, and
> in third-party apps supporting CryptoTokenKit"

([Apple — Use a smart card on Mac](https://support.apple.com/guide/deployment/use-a-smart-card-on-mac-depc47f60521/web))

This machine corroborates it from two directions (VERIFIED):

```
$ security authorizationdb read system.login.screensaver.unlock
    class      = evaluate-mechanisms
    mechanisms = [ CryptoTokenKit:login ]
    comment    = Do not modify. Performs unlock operations for screensaver.

$ cat /etc/pam.d/screensaver_ctk
    auth     required  pam_smartcard.so use_first_pass
    account  required  pam_opendirectory.so non_password_auth
```

Note `non_password_auth` — the account stack is explicitly told this authentication did not involve
a password.

**A "smart card" does not have to be hardware.** Apple's own Platform SSO ships as a
software-only CTK token (VERIFIED — read off
`/System/Library/ExtensionKit/Extensions/AccessKey.appex/Contents/Info.plist`):

```
NSExtensionPointIdentifier = com.apple.ctk-tokens
NSExtensionAttributes:
    com.apple.ctk.class-id             = com.apple.PlatformSSO.AccessKey
    com.apple.ctk.token-type           = smartcard
    com.apple.ctk.driver-class         = AccessKey.AccessKeyDriver
    com.apple.ctk.proprietaryCardUsage = true
    com.apple.ctk.consoleUserOnly      = true
```

There is no card, no reader, no AID on a physical chip — and it declares `token-type = smartcard`.
This is direct evidence that a virtual token is an intended, first-class configuration.

**The entitlement a third party needs is an ordinary one.** Apple's PIV token extension
(VERIFIED — `codesign -d --entitlements -` on `pivtoken.appex`):

```
com.apple.security.app-sandbox = true
com.apple.security.smartcard   = true
```

`com.apple.security.smartcard` is a standard App Sandbox entitlement available to any developer —
not a private or managed one.

**Enabling a third-party token for login is one root command.** `sc_auth` is a readable bash script
on this machine, and `enable_for_login` is eleven lines (VERIFIED — `sed -n '277,298p' /usr/sbin/sc_auth`):

```bash
enable_for_login() {
  check_root
  ...
  plugin_path=$(pluginkit -mv -i $classid | cut -f 4-)
  ...
  lsregister -trusted "$plugin_path"
}
```

It takes the `com.apple.ctk.class-id` from your extension's `Info.plist`, finds the containing app,
and marks it trusted with LaunchServices so the login/unlock context will load it. `man sc_auth`
describes it as: *"Enable the app extension for login and make the token available to the system
for authentication."* That is the entire deployment step beyond installing the app.

**The token can decline to demand a PIN.** From `TKToken.h` in the macOS 27.0 SDK (VERIFIED,
quoted from the header on this machine):

> "The resulting `authOperation` can be of any type based on `TKTokenAuthOperation`. For known
> types (e.g. `TKTokenPasswordAuthOperation`) the system will first fill in the context-specific
> properties (e.g. `password`) before triggering `finishWithError:`. **When no authentication is
> actually needed (typically because the session is already authenticated for requested
> constraint), return instance of `TKTokenAuthOperation` class instead of any specific subclass.**"

That sentence is the hinge. It means an Irys token extension can answer *"no auth needed"* to the
system and then decide for itself, inside
`tokenSession:signData:usingKey:algorithm:` , whether to actually perform the signature — gating it
on a face match the container app performed out-of-band moments earlier.

**What it cannot do:** present its own UI inside the CTK auth flow. Quinn again
([thread 726164](https://developer.apple.com/forums/thread/726164)), on a developer trying exactly
the "show my own dialog from a custom `TKTokenAuthOperation`" design: *"I don't think that goal is
achievable given the current CTK API."* The operation restarts without waiting. So the face scan
**must** be driven by the Irys agent (which already owns a lock-screen window via SkyLight), not by
the token extension.

### The sketch, concretely

1. Irys ships a CryptoTokenKit app extension with `com.apple.ctk.token-type = smartcard` and its own
   `class-id`, entitled `com.apple.security.smartcard`.
2. First run (root, once, in the installer or a privileged helper): `sc_auth enable_for_login -c
   com.jng011.irys.token`, then generate a P-256 key and `sc_auth pair -u <user> -h <pubkeyhash>`
   to bind it to the account. Pairing modifies the user's keychain, so it happens in an unlocked
   session.
3. At the lock screen, macOS sees a "card" present and offers smart-card unlock. It asks the token
   to sign the challenge.
4. The token extension returns a bare `TKTokenAuthOperation` (no PIN), then asks the Irys agent over
   XPC: *has the face matched in the last N seconds?* If yes, sign. If no, fail the operation and
   let macOS fall back to the password field.
5. **No password is stored anywhere. `KeystrokeInjector.swift` and the retrievable password blob
   both go away.**

### What is genuinely unverified about this

I did not pair a token or install an extension — that would modify the machine, and this task is
read-only. Specifically unknown:

- Whether the modern lock screen will actually offer a third-party CTK token, or whether the
  `use-login-window-ui` path is as closed to CTK as it is to authorization plugins. The presence of
  `system.login.screensaver.unlock → CryptoTokenKit:login` and `/etc/pam.d/screensaver_ctk` says it
  should; nothing proves it does. **This is the decisive unknown.**
- Whether a PIN-less token is accepted for login at all, or whether `pam_smartcard.so` insists on a
  `TKTokenSmartCardPINAuthOperation`. (`sc_auth create-ctk-identity -t bio|none` offering a `none`
  protection level is suggestive but not proof.)
- Whether Apple restricts login to known class IDs. `enable_for_login` taking an arbitrary
  `class-id` argument argues no.
- The login-keychain consequence. Apple's guide warns that without a key-management key on the card,
  smart-card users get repeated keychain prompts. At *screensaver* unlock the keychain is already
  open, so this may be a non-issue — but it is unconfirmed.
- Whether an unpaired-but-present token triggers the pairing dialog every launch
  (`sc_auth pairing_ui` is currently `enabled` on this machine — VERIFIED).
- **A real risk worth naming:** a virtual token that signs on demand, gated only by an app's own
  say-so, is a credential that never leaves the machine but also never leaves the attacker's reach
  if they can talk to the Irys agent's XPC endpoint. The XPC peer check (code-signing requirement
  on the connecting process) becomes load-bearing in a way nothing in the current design is.

**Finding: CryptoTokenKit is the only identified route to password-free screen unlock that uses
public API, keeps Touch ID working, and needs one root command rather than an authorization
database rewrite. Its foundations are VERIFIED; whether it actually reaches the modern lock screen
is UNVERIFIED and is the highest-value experiment in this project.**

## Finding 9 — the rest of the authorization database, ranked (VERIFIED)

`/System/Library/Security/authorization.plist` holds **149 rights** on macOS 27.0, of which only
**15** are `evaluate-mechanisms` (the extensible kind) — the other 134 are `rule`, `user`, `allow`
or `deny` (VERIFIED — parsed with `plistlib`). The 15 mechanism-based rights are:

```
com.apple.KerberosAgent            com.apple.builtin.confirm-access
com.apple.builtin.confirm-access-password
com.apple.builtin.generic-new-passphrase
com.apple.builtin.generic-unlock   com.apple.builtin.sc-kc-new-passphrase
system.disk.unlock                 system.keychain.create.loginkc
system.login.console               system.login.done
system.login.filevault             system.login.fus
system.login.screensaver.unlock    system.restart
system.shutdown
```

Ranked by (value to user) × (feasibility) × (how little it weakens the security story):

| # | Target | Right / path | Value | Feasibility | Security cost | Verdict |
|---|---|---|---|---|---|---|
| 1 | **`sudo` in Terminal** | `/etc/pam.d/sudo_local` | High — daily, visible, "authenticate sudo with your face" is a headline feature | Good, *if* library validation permits (Finding 6) | **Low.** No credential stored; the module only returns success/failure | **Build this** |
| 2 | **Screen unlock without a stored password** | CryptoTokenKit token (Finding 8) | Highest — it is the whole app | Unproven but plausible | **Negative cost** — removes the stored password | **Prove or disprove this** |
| 3 | **Keychain item access prompts** | `com.apple.builtin.generic-unlock`, `system.keychain.create.loginkc` — both `evaluate-mechanisms` | Medium | Requires a SecurityAgent plugin + authorizationdb rewrite, but these are *narrow* rights — rewriting them does not touch Touch ID unlock | Medium — you are inserting yourself into keychain decisions | Interesting, second tier |
| 4 | **System Settings padlock** | `system.preferences` and ~20 `system.preferences.*` | Medium — visible, frequent | **Blocked.** `class = user`, `group = admin`, `authenticate-user = true` (VERIFIED). No mechanism array; cannot be hooked without converting it to `evaluate-mechanisms`, which is a system-wide rewrite | Medium-high | Not worth it |
| 5 | **Installer / admin-rights prompts** | `system.privilege.admin` (`class = user`), `system.install.*` | Medium | Same blocker as #4 — `class = user`, no mechanisms | Medium-high | Not worth it |
| 6 | **`sudo` via Terminal.app's own prompt / `com.apple.security.sudo`** | `rule = ['entitled', 'authenticate-session-owner']` | Low (duplicate of #1) | Rule-class, not hookable | — | Skip |
| 7 | **Other apps' `LAContext` prompts** | — | High if possible | **Impossible.** Confirmed by Finding 7: no provider extension point exists. `LAContext` is consumer-only and its policy set is a closed enum | — | **Confirmed unavailable** |
| 8 | **`system.restart` / `system.shutdown`** | `evaluate-mechanisms`, with `builtin:authenticate,privileged` in the chain | Very low | Technically hookable | Low | Curiosity only |
| 9 | **`system.disk.unlock`** | `evaluate-mechanisms`: `DiskUnlock:prompt`, `DiskUnlock:unlock,privileged` | Low-medium (unlock an encrypted external volume by face) | Hookable, narrow | Low | A genuinely fun, low-risk demo |
| 10 | **FileVault pre-boot** | `system.login.filevault` | High | **Impossible.** Runs in the pre-boot recovery environment — no camera stack, no Irys | — | Dead |

Interesting rights encountered along the way, for the record (all VERIFIED from the plist):
`com.apple.Safari.show-passwords`, `com.apple.Safari.show-credit-card-numbers`,
`com.apple.security.syntheticinput` (`rule = authenticate-session-owner` — notable given Irys
synthesises input today), `com.apple.tcc.util.admin`, `com.apple.activitymonitor.kill`,
`com.apple.system-extensions.admin`, `system.csfde.requestpassword`,
`com.apple.ServiceManagement.daemons.modify`, `system.platformsso.auth`.

---

# Verdict

**Can Irys stop storing the user's password?**

**For screen unlock: probably yes, but not by any route that is both cheap and proven today.** The
project's standing assertion — "macOS has no API that lets a third-party app authorize a login" —
is **too strong and should be corrected.** Three routes exist; each has a specific, nameable cost:

| Route | Eliminates stored password? | Cost | Status |
|---|---|---|---|
| **CryptoTokenKit virtual token** | **Yes** | One root command (`sc_auth enable_for_login`) + pairing. Keeps Touch ID. Shifts trust onto an XPC peer check | **Foundations VERIFIED, end-to-end UNVERIFIED — test this** |
| **SecurityAgent plugin** (rewrite `system.login.screensaver`) | **Yes** | **Machine loses Touch ID unlock and the modern lock screen.** Root, `.pkg`, system-wide authorizationdb rewrite | Mechanism VERIFIED, works on macOS 26. Cost is unacceptable for a consumer app |
| **Platform SSO** | Yes | Requires MDM + an identity provider | VERIFIED unavailable to an unmanaged consumer Mac |
| Keystroke injection (today) | No | — | Shipping |

So the correct statement for the README and the project notes is not "macOS has no API". It is:

> macOS has no API that lets a third-party app authorize a login *while preserving Touch ID and the
> modern lock screen*, **except possibly CryptoTokenKit, which we have not yet tested.**

**Beyond screen unlock, one clearly real feature exists: `sudo`.** `/etc/pam.d/sudo_local` is
Apple's own documented extension point, the same one `pam_tid.so` uses; a module there needs no
stored credential at all. Its one blocker (macOS 26+ library validation on `sudo`) is settled by a
single command.

**If both of those fail, the second-best improvements to the current design, in order:**

1. **Shrink the plaintext window.** `KeystrokeInjector.typeAndReturn` already takes `Data` rather
   than `String` specifically so the caller can hold a zeroable buffer — but it then does
   `String(data:encoding:)` internally, creating an immutable Swift `String` that cannot be wiped
   and whose lifetime is the allocator's business. Type from the `Data` buffer directly
   (`CGEvent.keyboardSetUnicodeString` over a `UTF16` view built in a `mutating withUnsafeBytes`
   scope) and explicitly zero every intermediate. Small diff, real reduction in exposure.
2. **Bind the stored credential to the face match, not just to the session.** Today the session key
   is unwrapped once per launch with Touch ID and then cached in RAM for the whole session
   (`_cachedKey`), so the credential is decryptable by anything that can reach
   `SecureCredentialManager` for hours. Deriving the final unwrap from something produced by the
   match itself — even a per-unlock nonce the pipeline must supply — narrows that.
3. **Bind the blob to the machine and the app.** It already uses
   `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`; add an application-specific password
   (`kSecAccessControlApplicationPassword`) so a copied keychain is inert.
4. **Never make `.userPresence` removal the default** (§8 of CLAUDE.md). The tradeoff analysis there
   is correct and this document does not change it.

---

# What I would build first

**Two experiments before any code, in this order. Together they are under an hour.**

**Experiment A — settle the `sudo` library-validation question (five minutes, zero risk):**

```bash
sudo codesign -d --entitlements - /usr/bin/sudo 2>&1 | grep -i library-validation
# then, the real test:
brew install pam_reattach          # a known third-party PAM module
# add to /etc/pam.d/sudo_local ABOVE pam_tid.so, then `sudo -k; sudo true` from inside tmux
log show --last 2m --predicate 'eventMessage CONTAINS "Library Validation"'
```

If `pam_reattach` loads, a custom module will too, and "authenticate `sudo` with your face" is
green.

**Experiment B — settle the CryptoTokenKit question (an afternoon, reversible):**

Build the smallest possible CTK app extension — one P-256 key, `token-type = smartcard`, a bare
`TKTokenAuthOperation` for every auth request, signing unconditionally. Then:

```bash
sudo sc_auth enable_for_login -c <your class-id>
sc_auth identities                      # does the system see the virtual token?
sudo sc_auth pair -u $(whoami) -h <hash>
# lock the screen and look at it
```

If the lock screen offers the token, **the entire password-storage problem is solved** and the
roadmap changes shape. If it does not, CryptoTokenKit is dead for unlock and the honest answer
reverts to "password storage cannot be eliminated for screen unlock", with `sudo` as the consolation
prize. Everything is reversible with `sc_auth unpair` and deleting the app.

**Then, whichever way those land, build the `sudo_local` PAM module.** It is independent of the
unlock question, it is on a supported path, it stores nothing, it uninstalls by deleting one line,
and it directly answers the user's "what else can this authenticate?" question. Shape: a C shim of
a few hundred lines doing `pam_sm_authenticate` → XPC to the Irys agent → `PAM_SUCCESS`/`PAM_AUTH_ERR`,
with `pam_reattach` read first for the tmux/session-attachment problem.

---

# What remains unknown

1. **Does the modern lock screen surface a third-party CryptoTokenKit token?** The decisive
   question. `system.login.screensaver.unlock → CryptoTokenKit:login` and `/etc/pam.d/screensaver_ctk`
   say it should. Nothing here proves it. Experiment B settles it.
2. **Does `/usr/bin/sudo` carry `com.apple.private.security.clear-library-validation` on macOS 27.0?**
   Unreadable without root from this task. Blocks the entire PAM feature if absent.
3. **Will `pam_smartcard.so` accept a PIN-less token for unlock**, or does it require a
   `TKTokenSmartCardPINAuthOperation`?
4. **Does a rewritten `system.login.screensaver` still admit third-party plugins on 27.0?** Verified
   on 26 via a third-party report; unverified on 27.
5. **Do CTK login tokens have a login-keychain consequence at screensaver unlock?** Apple warns about
   repeated keychain prompts for smart-card users without a key-management key; at screensaver unlock
   the keychain should already be open, but this is untested.
6. **Whether a locally-installed (non-MDM) `com.apple.extensiblesso` profile is accepted.** Almost
   certainly not, but not attempted.
7. **Whether an unsigned or ad-hoc-signed SecurityAgentPlugin bundle loads**, and whether notarization
   is required for the bundle as opposed to the installer package. Inferred from XCreds/Jamf Connect
   shipping Developer ID bundles; not verified directly.
8. **The XPC peer-authentication design** for whichever route wins. Both the PAM shim and the CTK
   token move the trust boundary onto "is the process asking me really Irys, and is Irys really
   unmodified?" Nothing in the current codebase does this today, and getting it wrong would make
   either route *worse* than the stored password.

## Sources

Read on this machine (primary): `security authorizationdb read` for
`system.login.console`, `system.login.screensaver`, `system.login.screensaver.unlock`,
`system.preferences`, `system.privilege.admin`, `authenticate`;
`/System/Library/Security/authorization.plist`; all of `/etc/pam.d/`; `/usr/lib/pam/`;
`/usr/sbin/sc_auth` and `man sc_auth`; `codesign -d --entitlements -` on `authorizationhost`,
`coreauthd`, `pam_tid.so.2`, `pivtoken.appex`; `pluginkit -m -v -p com.apple.ctk-tokens`;
`Info.plist` of `pivtoken.appex` and `AccessKey.appex`; and the macOS 27.0 SDK headers
`AuthorizationPlugin.h`, `AuthorizationTags.h`, `SFAuthorizationPluginView.h`, `TKToken.h`,
`TKTokenConfiguration.h`, `LAContext.h`, `LAPublicDefines.h`, `SecAccessControl.h`.

Apple documentation and DTS:
[Use a smart card on Mac](https://support.apple.com/guide/deployment/use-a-smart-card-on-mac-depc47f60521/web) ·
[Platform SSO for macOS](https://support.apple.com/guide/deployment/platform-sso-for-macos-dep7bbb05313/web) ·
[Extensible SSO payload settings](https://support.apple.com/guide/deployment/extensible-single-sign-on-payload-settings-depfd9cdf845/web) ·
[apple/device-management](https://github.com/apple/device-management/blob/release/mdm/profiles/com.apple.extensiblesso.yaml) ·
DevForums [110667](https://developer.apple.com/forums/thread/110667),
[711212](https://developer.apple.com/forums/thread/711212),
[726164](https://developer.apple.com/forums/thread/726164),
[751017](https://developer.apple.com/forums/thread/751017),
[765869](https://developer.apple.com/forums/thread/765869),
[772227](https://developer.apple.com/forums/thread/772227),
[798550](https://developer.apple.com/forums/thread/798550),
[819454](https://developer.apple.com/forums/thread/819454).

Third party (treat as UNVERIFIED unless corroborated above):
[Elliot Jordan — authorization database mechanisms](https://www.elliotjordan.com/posts/macos-authdb-mechs/) ·
[XCreds Admin Guide](https://twocanoes.com/knowledge-base/xcreds-admin-guide/) ·
[Jamf Connect loginwindow guide](https://docs.jamf.com/jamf-connect/2.1.2/administrator-guide/Editing_the_macOS_loginwindow_application.html) ·
[Homebrew discussion 6597 — third-party PAM on macOS 26](https://github.com/orgs/Homebrew/discussions/6597) ·
[pam_reattach](https://github.com/fabianishere/pam_reattach) ·
[pam-watchid](https://github.com/mostpinkest/pam-watchid) ·
[pam_wtid](https://github.com/inickt/pam_wtid) ·
[theevilbit — Authorization Plugins](https://theevilbit.github.io/beyond/beyond_0028/).
