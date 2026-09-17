# 003 — External biometric unlock devices, and whether CryptoTokenKit is a way out

Research date: 2026-09-16. Machine: macOS 27.0 (Darwin 27.0.0), Apple Silicon, Xcode 27.0,
macOS 27.0 SDK. Companion to `002-macos-auth-integration.md` (authorization stack, API side).

Every claim is tagged **VERIFIED** — read from a shipped file on this machine, from a
vendor's own source code, or from Apple documentation — or **UNVERIFIED** — marketing,
press, forum, or inference. Where a vendor's marketing and its own engineering writing
disagree, both are quoted.

**The short version.** The Kickstarter device stores your password and types it, exactly
like Glance does. macOS *does* have a real password-free authentication pathway
(CryptoTokenKit / PIV smartcard), it *does* cover screen unlock and not just the login
window, and it is *open to third parties* — but the public API makes it structurally
impossible for a software-only token to enter it. Proof is in §4.4. There is a private
Apple SPI that would do it (§4.6) and it is not usable.

---

## 1. The Kickstarter product is "immurok", and it types your password

The user remembered the name correctly. **immurok** (https://immurok.com) — a
keychain-sized BLE fingerprint key, live on Kickstarter to 2026-09-22, US$59, targeting
Mac, Windows and Linux. WCH CH592F RISC-V MCU, BLE 5.4, R559S capacitive sensor, ECDH
P-256 pairing, HMAC-SHA256 challenge/response, fingerprint matching on-device.
**VERIFIED** — vendor build log,
https://hackaday.io/project/206046-immurok-a-wireless-fingerprint-auth-key/details

It is not Touch ID, not FIDO2/CTAP, not a smartcard, and touches the Mac's Secure Enclave
not at all.

### What it does on macOS, from the vendor's own published source

https://github.com/immurok/app-macos — README, first bullet (**VERIFIED**):

> **Screen unlock** — Detects lock screen, **types your password** on fingerprint match

The repo contains a module named `AuthInjectionKit` and `Sources/AuthInjector.swift`,
which posts synthesised events at the HID tap — byte for byte the mechanism in Glance's
`KeystrokeInjector.swift` (**VERIFIED**, fetched from the repo):

```swift
// immurok/app-macos — Sources/AuthInjector.swift:222-226
let src = CGEventSource(stateID: .combinedSessionState)
guard let down = CGEvent(keyboardEventSource: src, virtualKey: 0x24, keyDown: true),
      let up   = CGEvent(keyboardEventSource: src, virtualKey: 0x24, keyDown: false) else { return false }
down.post(tap: .cghidEventTap)
up.post(tap: .cghidEventTap)
```

Their engineering blog states the credential storage outright (**VERIFIED** —
https://immurok.com/blog/desktop-fingerprint-auth-on-mac-and-linux/):

> "it keeps your login password in the macOS Keychain and types it *only after*
> verifying a cryptographically signed match"

…and concedes that macOS "blocks third-party PAM modules from dismissing" the lock screen,
which is why they fall back to keystroke synthesis. That concession is independently
corroborated by §4.2 below: the screensaver PAM stack is fixed, with named service files
for password, smartcard, and LocalAuthentication, and no extension point.

### Where the marketing goes vague

The product page says "PAM integration on macOS and Linux" and "Lock screen → touch →
unlocked" (**VERIFIED** as quotes). Both are true; together they imply something false.
The PAM module (`pam/pam_immurok.c`, talking to the menu bar app over a Unix socket at
`~/.immurok/pam.sock`, hand-installed into `/usr/lib/pam/` with an `/etc/pam.d/sudo_local`
edit) covers **sudo only**. The lock screen is the password-typing path. Putting both in
one sentence without saying which covers which is the vendor being vague at precisely the
point that matters.

**Verdict: immurok is a USB/BLE HID device plus a helper app that stores your password and
replays it (mechanism 3), with a PAM module for sudo (mechanism 4). It is architecturally
the same product as Glance with a fingerprint sensor instead of a webcam. It has not found
a hook Glance is missing.** Glance's two-tier Keychain design (Touch-ID-gated session key
unwrapping an ungated blob) is arguably the better of the two.

---

## 2. Third-party Touch ID: no pathway exists

Apple's security guide describes Magic Keyboard with Touch ID pairing: the keyboard and the
Mac's Secure Enclave "exchange public keys, rooted in the trusted Apple certificate
authority (CA)", using "hardware-held attestation keys and Elliptic Curve Diffie-Hellman
Exchange Ephemeral (ECDHE)", with the shared key established **during factory
manufacturing**. **VERIFIED** —
https://support.apple.com/guide/security/magic-keyboard-with-touch-id-secf60513daa/web

The trust root is an Apple CA plus an Apple factory-provisioned key. No third party can
mint an attestation key the Secure Enclave will accept. Apple silicon is required; Intel
and T2 Macs get a plain Bluetooth keyboard (**VERIFIED** — https://support.apple.com/en-us/121954).

MFi covers iAP and connectivity hardware, nothing biometric (**VERIFIED** for scope,
https://mfi.apple.com/en/who-should-join.html; **UNVERIFIED** as a negative — Apple
publishes no exclusion list, so "MFi does not cover Touch ID" is inference from the absence
of any such tier and of any shipping product).

The one product that genuinely gets Secure Enclave Touch ID is **Standalone Touch ID**
(https://standalonetouchid.com), which **harvests the real logic board out of an Apple Magic
Keyboard with Touch ID** and re-houses it (**VERIFIED** —
https://hackaday.com/2022/12/26/standalone-touch-id-for-your-desktop-mac/). Genuine Apple
hardware, therefore genuine Secure Enclave, therefore full login-window and FileVault
support — and therefore not a pathway anyone can build software against.

---

## 3. Product comparison

| Product | Real mechanism | Login window | Screen unlock | Install footprint | Honest security rating |
|---|---|---|---|---|---|
| **Apple Magic Keyboard with Touch ID** | Genuine Secure Enclave. Keyboard is a *sensor*; match and key release happen in the Mac's SEP over a factory ECDHE channel. **VERIFIED** | Yes | Yes | None | **Strongest.** No app ever holds the password; template never leaves SEP. |
| **Standalone Touch ID** | Same — a harvested Apple logic board. **VERIFIED** | Yes | Yes | None claimed | Same, with unknown supply-chain provenance. |
| **immurok** | BLE device + menu bar app; password in Keychain, typed via `CGEvent` at `.cghidEventTap`. PAM module for sudo only. **VERIFIED from source** | No — it types into whatever has focus | Yes, by typing | Menu bar app, Accessibility permission, optional root install of `pam_immurok.so` | **Weak for unlock.** The BLE crypto protects the *trigger*, not the *credential*. Your login password is recoverable from disk. Strong for sudo and SSH. |
| **YubiKey Bio Multi-protocol Edition** | FIDO2 with on-device match, *plus* a PIV applet. On macOS the PIV applet does genuine smartcard login — but **with a PIN, not the fingerprint**: Yubico ships fingerprint-for-PIV only in the Windows minidriver. **VERIFIED** — https://support.yubico.com/s/article/YubiKey-Bio--Multiprotocol-Edition | Yes (PIV) | Yes (PIV) | None — uses Apple's built-in `pivtoken.appex` | **Strong**, and the only consumer device doing real macOS login cryptographically. But on macOS the biometric is not what authenticates login; the PIN is. |
| **YubiKey 5 series** | PIV smartcard. **VERIFIED** — https://support.yubico.com/s/article/YubiKey-for-macOS-login | Yes | Yes | None | Strong; no biometric. |
| **Kensington VeriMark / Guard** | FIDO2/U2F, on-device match. Windows Hello is the real integration; macOS gets a provisioning tool (`Ctapfma`) and tap-and-go for web logins. **No macOS login integration.** **VERIFIED** — https://www.kensington.com/software/verimark-setup/verimark-guard-setup-guide/ | No | No | Provisioning tool | Strong as a web authenticator; irrelevant to macOS login. |
| **Generic USB-C "Mac login" fingerprint dongles** | Helper app + stored password in every case examined. **UNVERIFIED** as a blanket claim; verified only for immurok | No | By typing | Helper app + Accessibility | Weak. |

**Rule of thumb for reading any of these listings: if the product does not say the words
*PIV*, *smartcard*, or *CryptoTokenKit*, it is storing your password.** No consumer
accessory has found a fourth option.

---

## 4. CryptoTokenKit / PIV — the investigation

This is the part that matters. macOS has a real, supported, documented, password-free
authentication pathway. Four questions: is it live by default, does it reach screen unlock,
can a third party enter it, and can a *software-only* component enter it.

### 4.1 It is live in the stock login configuration

`security authorizationdb read system.login.console` (**VERIFIED**, this machine) is
`class: evaluate-mechanisms`, and the chain contains, in order:

```
builtin:prelogin, builtin:policy-banner, loginwindow:login, builtin:login-begin,
builtin:reset-password,privileged, loginwindow:FDESupport,privileged,
builtin:forward-login,privileged, builtin:auto-login,privileged,
builtin:authenticate,privileged, builtin:login-success, loginwindow:success,
HomeDirMechanism:login,privileged, HomeDirMechanism:status, MCXMechanism:login,
CryptoTokenKit:login, loginwindow:done
```

`CryptoTokenKit:login` is present by default, and
`/System/Library/CoreServices/SecurityAgentPlugins/CryptoTokenKit.bundle` is the
`com.apple.securityAgentPlugins.CryptoTokenKit` plugin that implements it (**VERIFIED**,
on disk). This is not hypothetical configuration; it ships enabled.

The binding is a public-key hash written into the user's directory record.
`/usr/sbin/sc_auth` is a **readable bash script** on this machine, and its header comment
states the mechanism outright (**VERIFIED**):

> You can log in with a SmartCard if the authentication_authority field of your user record
> contains an entry of the form `;pubkeyhash;THEHASH` where THEHASH is the hex encoding of
> the SHA1 of the public key to be used.

`man SmartCardServices` (**VERIFIED**) adds what the keys do:

> Authentication is performed using the PIV Authentication Identity (9a). For login, the Key
> Management key (9d) is used to unlock the encrypted harddrive (Apple Silicon devices) and
> to unlock Keychain.

Genuinely password-free: the login window issues a challenge, the token signs it with 9a,
and 9d unwraps the keychain and the FileVault volume key. No password is stored anywhere.

### 4.2 It reaches screen unlock too — and here 002's conclusion needs a correction

`system.login.screensaver` is `class: rule` with `rule = [use-login-window-ui]`, not
`evaluate-mechanisms` (**VERIFIED**, confirmed independently on this machine). Companion
document 002 reads that as "the authorization-plugin route is closed for screen unlock."
For *authorization plugins*, that is right. **For CryptoTokenKit it is not** — screen
unlock has its own dedicated smartcard PAM stack, and it ships by default.

`ls /etc/pam.d/` on this machine shows a family of service files with suffixes
(**VERIFIED**, all contents read):

| Service file | `auth` module | What it is |
|---|---|---|
| `screensaver` | `pam_opendirectory.so` | password |
| `screensaver_ctk` | `pam_smartcard.so use_first_pass` | **smartcard / CryptoTokenKit** |
| `screensaver_la` | `pam_localauthentication.so` + `pam_aks.so` | Touch ID / LocalAuthentication |
| `screensaver_aks` | `pam_aks.so` | Apple Key Store credential release |
| `screensaver_new`, `screensaver_new_ctk` | as above, `pkinit` variant | newer screensaver UI |
| `authorization`, `authorization_ctk`, `authorization_la`, `authorization_aks`, `authorization_lacont` | same pattern | authorization dialogs; `_lacont` is `continuityunlock` (Apple Watch) |

So `use-login-window-ui` hands the screensaver to loginwindow's UI, and loginwindow selects
a PAM service by **credential type**, appending `_ctk`, `_la`, `_aks` or nothing. A
smartcard unlocks the screen natively, with no password and no keystrokes. Apple's
deployment guide lists "Screensaver" among supported services (**VERIFIED** —
https://support.apple.com/en-is/guide/deployment/depc47f60521/web), and OpenSCToken's
documentation lists "Unlock screen saver" among tested applications (**VERIFIED** —
https://github.com/frankmorgner/OpenSCToken).

The important structural point: **that suffix list is closed.** There is no
`screensaver_face`, and nothing in `/etc/pam.d` is an extension point — the suffix is chosen
inside loginwindow/SecurityAgent, not discovered from the filesystem. You cannot add a fifth
credential type. You can only be one of the four, and only `_ctk` is reachable by a
third-party product.

Worth noting for its own sake: `screensaver_la` / `screensaver_aks` are how Touch ID and
Apple Watch unlock the screen. `pam_localauthentication.so` calls
`LACopyResultOfPolicyEvaluation` / `evaluatePolicy:options:error:` and `pam_aks.so` releases
the stashed credential from the Secure-Enclave-protected keybag (**VERIFIED** by `strings`
on both modules). That is Apple's own, sanctioned version of "store the credential and
release it on a biometric" — the legitimate implementation of what Glance does by hand with
a Keychain blob and synthetic keystrokes. It is not third-party extensible.

### 4.3 sudo works out of the box

`/etc/pam.d/sudo` on this machine (**VERIFIED**, unmodified):

```
auth       include        sudo_local
auth       sufficient     pam_smartcard.so
auth       required       pam_opendirectory.so
```

`pam_smartcard.so` is **uncommented and `sufficient` by default**. A paired PIV token
authorises sudo with no configuration at all. (`sudo_local` is the file where
`pam_tid.so` — Touch ID for sudo — is enabled; this is also where immurok's module goes.)

`strings /usr/lib/pam/pam_smartcard.so.2` confirms it is a real CTK client:
`copyAvailableTokensContext:hints:error:`, `findTokenByHash:`, `bindUserAm:pubKeyHash:error:`,
`performLogin:tokenId:pubKeyHash:pin:kerberosPrincipal:error:`, `Enter PIN for '%s': `,
`pkinit`, `token_ctk` (**VERIFIED**).

### 4.4 Can a software-only token enter this pathway? No — and here is the proof

Three independent, primary-source facts, which together close the question.

**(a) Persistent (software) tokens are explicitly excluded from login.** Apple DTS:

> "Modern smart card support is based on CryptoTokenKit (CTK) app extensions. There are two
> flavours of those: a smart card token driver, which subclasses `TKSmartCardTokenDriver`;
> a persistent token driver, which subclasses `TKTokenDriver`.
> **A smart card token can be use for login. A persistent token cannot.**"

**VERIFIED** — https://developer.apple.com/forums/thread/745234

Corroborated by the shipped extensions on this machine (**VERIFIED** via
`pluginkit -m -p com.apple.ctk-tokens` and `plutil -p` on each `Info.plist`):

| Extension | `com.apple.ctk.token-type` | `com.apple.ctk.aid` |
|---|---|---|
| `com.apple.CryptoTokenKit.pivtoken` | `smartcard` | `a000000308 00001000 0100` |
| `com.apple.PlatformSSO.AccessKey` | `smartcard` | `A000000909ACCE5501` (+ `proprietaryCardUsage`, `consoleUserOnly`) |
| `com.apple.CryptoTokenKit.ctkcard.ctkcardtoken` | *absent* | *absent* |
| `com.apple.PlatformSSOToken` | *absent* | *absent* |

The two with no `token-type` are the two software ones.

Apple's own `sc_auth` says the same from the other side. `man sc_auth` describes CTK
Identities — Secure-Enclave-backed keys you can create *today* with
`sc_auth create-ctk-identity -k p-256-ne -t bio`, a non-exportable SEP key gated by
**Touch ID** — as usable for (**VERIFIED**):

> "TLS authentication, email protection and SSL using ssh-keychain(8) library"

Login is conspicuously absent from that list. This is the closest thing on the system to
"a software token with a biometric gate," and Apple does not let it log you in.

**(b) A smartcard token cannot be constructed without a physical card.** This is the
decisive one, and it is in the macOS 27 SDK header `TKSmartCardToken.h` (**VERIFIED**, read
from disk). `TKSmartCardToken` has exactly one designated initializer, and it takes a
`TKSmartCard`:

```objc
- (instancetype)initWithSmartCard:(TKSmartCard *)smartCard
                              AID:(nullable NSData *)AID
                       instanceID:(NSString *)instanceID
                      tokenDriver:(TKSmartCardTokenDriver *)tokenDriver NS_DESIGNATED_INITIALIZER;

- (instancetype)initWithTokenDriver:(TKTokenDriver *)tokenDriver
                         instanceID:(NSString *)instanceID NS_UNAVAILABLE;
```

The cardless initializer is `NS_UNAVAILABLE`. And the only delegate callback that creates
one fires on hardware events:

```objc
/// Called by system when new SmartCard is detected. You must override this method to
/// create a new valid token TKSmartCardToken instance for @c smartCard.
- (nullable TKSmartCardToken *)tokenDriver:(TKSmartCardTokenDriver *)driver
                   createTokenForSmartCard:(TKSmartCard *)smartCard
                                       AID:(nullable NSData *)AID error:(NSError **)error;
```

So: login requires a smartcard token; a smartcard token requires a `TKSmartCard`; a
`TKSmartCard` comes only from the PC/SC layer, which on this machine has exactly two
providers — `/System/Library/CryptoTokenKit/com.apple.ifdreader.slotd` and
`usbsmartcardreaderd.slotd` (**VERIFIED**, directory listing). Both are reader daemons.
**A software-only token cannot enter the login pathway through the public API. This is a
structural bar, not a policy one.**

**(c) The iOS escape hatch is explicitly not on macOS.** `TKSmartCardTokenRegistrationManager`
(new in the 2025 SDK) registers a card by token ID without an insertion event — and its
availability annotation is (**VERIFIED**, `TKSmartCardTokenRegistrationManager.h`):

```objc
API_AVAILABLE(ios(26.0), macCatalyst(26.0), visionos(26.0)) API_UNAVAILABLE(macos, watchos, tvos)
```

It is for NFC cards on iOS. Unavailable on macOS.

### 4.5 The pathway *is* open to third parties — just not to software

Worth stating clearly, because it is the one encouraging finding. The extension point is
public. From the CryptoTokenKit framework's own `Info.plist` (**VERIFIED**, read on this
machine):

```
"NSExtensionSDK" => { "com.apple.ctk-tokens" => {
    "EXExtensionPointIsPublic" => true
    "NSExtensionHostEntitlement" => "com.apple.private.extension-host.ctk-tokens"
    "NSExtensionPrincipalClass" => "TKTokenDriverRequest"  ... } }
```

`EXExtensionPointIsPublic = true`. The private entitlement is on the *host* (`ctkd`), not on
the extension. No third-party entitlement is required.

And `sc_auth enable_for_login` — because `sc_auth` is a shell script, this is answerable
exactly rather than guessed (**VERIFIED**, whole function):

```bash
enable_for_login() {
  check_root
  plugin_path=$(pluginkit -mv -i $classid | cut -f 4-)
  if   [[ $plugin_path = */Contents/* ]]; then plugin_path=${plugin_path%/Contents/*}
  elif [[ $plugin_path = */PlugIns/*  ]]; then plugin_path=${plugin_path%/PlugIns/*}
  else echo "Token '$classid' not found. Please activate the app extension." 1>&2; exit 1
  fi
  /System/.../LaunchServices.framework/Support/lsregister -trusted "$plugin_path"
}
```

It does one thing: registers the *containing app* as trusted in the **system** LaunchServices
database, so the appex is discoverable from the login window — which runs before any user
session exists and so cannot see a per-user LS registration. It grants no capability. It is
a visibility fix. Notably, Apple built this specifically so a third-party CTK extension can
be present at the login window.

OpenSCToken is the working precedent: a third-party `TKSmartCardTokenDriver` app extension
whose documentation lists "Login to macOS" and "Unlock screen saver" among tested
applications, registered system-wide by running it as `sudo -u _securityagent` — the manual
equivalent of `enable_for_login` (**VERIFIED** — https://github.com/frankmorgner/OpenSCToken).
It requires a physical card. That is the pattern throughout: open to third parties *with
hardware*.

### 4.6 The two remaining loopholes, and why neither works

**Virtual PC/SC reader.** `man SmartCardServices` documents third-party reader drivers (IFD
handlers) as bundles in `/usr/local/libexec/SmartCardServices/drivers`, keyed on USB
vendor/product ID. `vsmartcard`'s `ifd-vpcd.bundle` is exactly this — a virtual reader whose
"card" is a socket to a software applet
(https://frankmorgner.github.io/vsmartcard/virtualsmartcard/README.html). On paper this is
the entire trick: virtual reader → virtual PIV applet → Apple's real `pivtoken.appex` → real
`sc_auth pair` → real password-free login and screen unlock.

In practice: reported broken on modern macOS. vsmartcard issue #303 on macOS 15.3.2 reports
`Failed to register IFD/CCID driver (error: -98)`, unresolved, no workaround (**VERIFIED** —
https://github.com/frankmorgner/vsmartcard/issues/303). On this machine
`/usr/local/libexec/SmartCardServices/drivers` **does not exist**; only Apple's
system-owned `/usr/libexec/SmartCardServices/drivers/ifd-ccid.bundle` is present
(**VERIFIED**). Apple has churned this component recently — Sonoma 14.0 swapped in its own
CCID driver, 14.1 reverted (**VERIFIED** —
https://blog.apdu.fr/posts/2023/11/apple-own-ccid-driver-in-sonoma/).

Even working, the footprint disqualifies it for a consumer app: root-owned files under
`/usr/local/libexec`, a daemon impersonating a card, and a dependency Apple is actively
moving. It is a strictly worse fragility than the SkyLight problem Glance already has.

**Apple's private virtual-token SPI.** `strings` on `/System/Library/Frameworks/CryptoTokenKit.framework/ctkd`
reveals a virtual token mechanism that needs no card (**VERIFIED**):

```
TKVirtualTokenPlugin, TKVirtualTokenExtension, TKVirtualTokenContext, TKVirtualTokenDelegate
kTKVirtualTokenIdentifier, kTKVirtualTokenName, kTKVirtualTokenXPCService, virtualTokenUUID
"TKVirtualTokenExtension: not in system session"
"TKVirtualTokenExtension: token not available"
"TKVirtualTokenExtension: unsupported platform"
com.apple.ctk.testonly
```

So a software token delivered over an XPC service is a concept that exists inside
CryptoTokenKit. But: nothing named `VirtualToken` appears in any public SDK header
(**VERIFIED**, grepped the whole macOS 27 `CryptoTokenKit.framework/Headers`), and no other
binary on this machine references it — `CryptoTokenKit` itself, `ctkcard`, `AccessKey.appex`
and the SecurityAgent plugin all score zero (**VERIFIED**). It sits next to the string
`com.apple.ctk.testonly` and emits "unsupported platform". **Reading: a test fixture, not a
shipping macOS facility.** Private, undocumented, unused, and unreachable.

For completeness, the anomaly that prompted this dig is resolved: Platform SSO's
`AccessKey.appex` declares `token-type = smartcard` with an AID despite being a software
Secure-Enclave credential — but `nm -u` on its binary shows it links `TKSmartCardToken`,
`TKSmartCardTokenDriver`, `TKSmartCardTokenSession`, and its symbols include
`initWithSmartCard:AID:instanceID:tokenDriver:` and
`tokenDriver:createTokenForSmartCard:AID:error:` (**VERIFIED**). Even Apple's own software
credential is constructed from a `TKSmartCard`. Apple therefore has *some* internal source
of cardless `TKSmartCard` objects; what it is, is still unknown (§6), but it is plainly not
in the public API, and it is not `TKVirtualToken`.

### 4.7 If the door ever opened, a face could replace the PIN

Worth recording, because it means the biometric is not the obstacle. In `TKToken.h` (macOS
27 SDK, **VERIFIED**), the token — not the system — decides how a key use is authorised:

```objc
- (nullable TKTokenAuthOperation *)tokenSession:(TKTokenSession *)session
                          beginAuthForOperation:(TKTokenOperation)operation
                                     constraint:(TKTokenOperationConstraint)constraint
                                          error:(NSError **)error;
```

The header's own comment: *"When no authentication is actually needed (typically because the
session is already authenticated for requested constraint), return instance of
`TKTokenAuthOperation` class instead of any specific subclass."*

A token that had already satisfied itself out-of-band — by recognising a face — returns the
bare `TKTokenAuthOperation`; the system prompts for nothing and the signature happens. No
PIN field, no password, nothing stored. The mechanism Irys wants exists. The lock is on the
hardware requirement in §4.4(b), not on the biometric.

---

## 5. What Irys should take from this

**1. The competition has found nothing. Stop looking over your shoulder.** immurok is a
funded, engineering-literate product with real cryptographic pairing and on-device
biometrics, and for screen unlock it does exactly what Glance does. Every product in §3
except the three genuine-Apple-hardware entries stores the password.

**2. The legitimate pathway exists, covers everything you want, and you cannot reach it.**
CryptoTokenKit/PIV gives login window, screen unlock, sudo, FileVault and keychain unlock
with no stored password — and it is genuinely open to third parties (§4.5). It is closed to
*software*, by the `NS_DESIGNATED_INITIALIZER` in `TKSmartCardToken.h` (§4.4b). Treat this
as settled and stop spending engineering time on it. If you want one line in the README
explaining why Irys types a password, it is: *macOS will only accept a cryptographic login
credential from a physical smartcard.*

**3. Do not chase the virtual reader.** Root-owned files in `/usr/local/libexec`, broken on
macOS 15+, on a component Apple has changed twice since 2023. It trades one private-API
fragility for a worse one.

**4. There is a real partial win available today: sudo.** `/etc/pam.d/sudo` already has
`auth sufficient pam_smartcard.so`, and `sudo_local` is the sanctioned place to add a
module. immurok ships `pam_immurok.so` + a Unix socket to its menu bar app and it genuinely
works. Irys could face-authorise `sudo` with **no stored password at all**, because PAM auth
is a yes/no verdict rather than a credential handoff. It does not fix the lock screen, but
it is a legitimate, password-free use of the face that the app is not currently making, and
it is a far better demo than it sounds. See 002 for the API-side view.

**5. Be honest in the README, and make it a differentiator.** Not "Irys unlocks your Mac
with your face" but "Irys recognises your face and then enters your password for you." The
whole category is vague about this. Being the one that is not is worth more than the
ambiguity buys.

**6. If a hardware product is ever interesting:** the only way to build a genuinely strong
Mac biometric unlock as a third party is to ship a PIV smartcard with an on-device sensor —
i.e. build the YubiKey Bio that Yubico did not finish, by writing the macOS middleware that
lets the fingerprint, rather than the PIN, release the PIV key. Yubico shipped that only for
Windows. That gap is real and nobody has filled it. Far outside the scope of this app, but
it is the honest answer to "what would actually be better."

---

## 6. What remains unknown

- **Where Apple's `AccessKey.appex` gets a cardless `TKSmartCard` from.** It links the
  smartcard classes and there is no card. Not `TKVirtualToken` (zero references). Likely a
  private slot provider. Answerable with
  `log stream --predicate 'subsystem == "com.apple.CryptoTokenKit"'` while Platform SSO
  authenticates. Low priority now — even if identified it will be private SPI — but it is
  the last genuinely open thread.
- **Whether a third-party appex declaring `token-type = smartcard` with a fabricated AID is
  ever instantiated absent a reader.** Header evidence in §4.4(b) says no. Untested
  empirically. Cheap to falsify: minimal `TKSmartCardTokenDriver` appex,
  `sc_auth enable_for_login -c <class-id>`, watch the logs. Worth one afternoon only if
  someone wants the question closed beyond doubt.
- **Whether `proprietaryCardUsage` / `consoleUserOnly` are honoured for third-party
  extensions** or gated on an Apple team ID. Undocumented anywhere I could find.
- **Whether `sc_auth create-ctk-identity -t bio` identities can be paired for login at all.**
  The man page omits login and `sc_auth pair` wants a card in a reader, but I did not test —
  testing modifies this machine's authentication authority, out of scope for a read-only
  investigation. Worth doing on a VM; it is the one cheap experiment that could overturn
  §4.4(a).
- **Whether macOS 26/27 added FIDO2 login-window support.** No evidence found, several
  statements that macOS accepts only passwords and the Secure Enclave for login, but no
  authoritative Apple statement for 27.0 specifically. Okta's Desktop MFA for macOS does use
  FIDO2 keys; their configuration page does not say whether that is a second factor *after*
  the password via their own plugin, which is what I would assume. Treat "FIDO2 cannot log in
  to macOS" as probable, not proven.
- **Whether immurok's BLE HID keyboard profile means the device types the password itself**
  on some platforms, rather than the host app. Their build log describes a dual channel
  (HID + custom GATT); the macOS source shows host-side `CGEvent` injection. Both may be
  true on different platforms.
- **Kensington VeriMark** was characterised from setup guides, not a teardown. Confident it
  has no login-window integration; have not proven it stores no password, only that it does
  not appear to attempt macOS login at all.
- **The generic-dongle row in §3** is category inference, not product-by-product
  verification.

---

## Sources

**Local primary sources (macOS 27.0, this machine):** `man sc_auth`, `man SmartCardServices`,
`/usr/sbin/sc_auth` (bash script), `security authorizationdb read system.login.console` /
`system.login.screensaver` / `authenticate`, all of `/etc/pam.d/` (notably `sudo`,
`sudo_local`, `screensaver*`, `authorization*`), `strings` on `pam_smartcard.so.2` /
`pam_localauthentication.so.2`, `pluginkit -m -p com.apple.ctk-tokens`, `Info.plist` of
`CryptoTokenKit.framework` / `pivtoken.appex` / `ctkcardtoken.appex` / `AccessKey.appex` /
`PlatformSSOToken.appex`, `nm -u` and `strings` on `AccessKey` and `ctkd`,
`/System/Library/CryptoTokenKit/`, `/System/Library/CoreServices/SecurityAgentPlugins/`,
and the CryptoTokenKit headers in the macOS 27.0 SDK (`TKToken.h`, `TKSmartCardToken.h`,
`TKTokenConfiguration.h`, `TKSmartCardTokenRegistrationManager.h`).

**Web:**
- immurok — https://immurok.com/ · https://immurok.com/blog/desktop-fingerprint-auth-on-mac-and-linux/ · https://hackaday.io/project/206046-immurok-a-wireless-fingerprint-auth-key/details · https://github.com/immurok/app-macos
- Apple Platform Security, Magic Keyboard with Touch ID — https://support.apple.com/guide/security/magic-keyboard-with-touch-id-secf60513daa/web
- Magic Keyboard with Touch ID tech specs — https://support.apple.com/en-us/121954
- Apple Deployment, supported smart card functions — https://support.apple.com/en-is/guide/deployment/depc47f60521/web
- Apple Deployment, advanced smart card options — https://support.apple.com/guide/deployment/advanced-smart-card-options-dep7b2ede1e3/1/web/1.0
- Apple DTS on CTK token flavours and login — https://developer.apple.com/forums/thread/745234
- Apple, Authenticating Users with a Cryptographic Token — https://developer.apple.com/documentation/CryptoTokenKit/authenticating-users-with-a-cryptographic-token
- OpenSCToken — https://github.com/frankmorgner/OpenSCToken
- vsmartcard virtual reader — https://frankmorgner.github.io/vsmartcard/virtualsmartcard/README.html · issue #303 https://github.com/frankmorgner/vsmartcard/issues/303
- Ludovic Rousseau on Apple's CCID driver in Sonoma — https://blog.apdu.fr/posts/2023/11/apple-own-ccid-driver-in-sonoma/
- Yubico — https://support.yubico.com/s/article/YubiKey-Bio--Multiprotocol-Edition · https://support.yubico.com/s/article/YubiKey-for-macOS-login
- Kensington VeriMark Guard setup — https://www.kensington.com/software/verimark-setup/verimark-guard-setup-guide/
- Standalone Touch ID — https://standalonetouchid.com/ · https://hackaday.com/2022/12/26/standalone-touch-id-for-your-desktop-mac/
- Apple MFi — https://mfi.apple.com/en/who-should-join.html
