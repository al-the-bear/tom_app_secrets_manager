# tom_secrets_app

> Part of the Tom Secrets Manager by Peter Nicolai Alexis Kyaw, BSD-3-Clause.

The Tom Secrets Manager's desktop app on macOS, Linux and Windows: the
composition root over `tom_secrets_ui`'s screens and `tom_secrets_desktop`'s
host.

## Overview

The app is a password manager and the editor for system secrets in one
window. It is a client of the user's secrets service: the service holds the
unlocked vaults and answers the programs on the machine; the app starts it,
unlocks and locks it, edits the vaults through it, and answers the approvals
it asks for.

- One instance per user; a second launch brings the window to the front.
- Started at login with `--hidden` it starts in the tray; closing the window
  keeps it there, and it quits only from the tray menu (DP-30). Quitting
  leaves the service running (BP-14).
- The window is kept out of screen capture by default (DP-33).

The package is an application: nothing imports it, so it carries no
`doc/api/` and no `example/`. Its map is the
[user guide](doc/user_guide.md), which walks every screen.

## Installing

The released app is an archive per platform; see
[Installing](../README.md#installing) in the repository README.

## Building and running

The app talks to the secrets service of the user who runs it. It finds the
service in the user's runtime directory, starts it from `tom_secrets_service`
beside the app with `bootstrap.yaml` in the data directory, and keeps the
admin key in the OS keychain, where `tsm` finds it too. The service takes
admin commands only from the app beside it, `tsm` beside it, or an
executable its bootstrap names in `admin_executables`.

```text
flutter run -d macos     # or linux, windows
flutter build macos      # build/macos/Build/Products/Release/tom_secrets_app.app
```

A development build has no service beside it: name one with `TSM_SERVICE`,
or write a demo installation with `tom_secrets_desktop`'s
`tool/demo_installation.dart` (see its
[README](../tom_secrets_desktop/README.md#testing)). The full release, with
`tsm` and the service inside the app, is `tom_secrets_build`'s `ci.sh
:release` ([README](../tom_secrets_build/README.md#the-release)).

Platform requirements:

- **macOS** builds through Swift Package Manager (no CocoaPods); the app is
  not sandboxed (`macos/Runner/*.entitlements` says why).

### The macOS AutoFill provider

`macos/TomSecretsAutofill` is the credential provider extension
(part-os-integration, DP-50, DP-51): an `ASCredentialProviderViewController`
with a small SwiftUI list, no Flutter engine. It reads the encrypted
snapshot of the personal and shared vaults' logins the app writes into the
App Group container, after Touch ID or the login password releases its key
from the keychain, matches the field's site like the browser extension,
offers a search, and fills the login picked (or a one-time code on macOS
15). It cannot save a login.

Passkeys (macOS 14, `ProvidesPasskeys`):

- **Signing in.** The site's passkeys from the snapshot are listed and the
  one picked signs (`ASPasskeyAssertionCredential`). The kit is the
  authenticator: ES256 or Ed25519, the flags user present, verified,
  backup eligible and backed up, the counter 0.
- **Creating one.** A new passkey is made with the site's first supported
  algorithm (`none` attestation). The extension then writes the one file
  it writes, the pending file `TomSecretsAutofill/pending-passkeys.tsmaf`
  in the App Group container: the snapshot's sealed format under the
  lasting pending key (keychain account `pending-key`, the app's).
- **Into a vault.** The pending file's passkeys can sign in at once. The
  app saves them into a vault at its next sync and clears the file.

- Its core, `macos/TomSecretsAutofillKit` (a Swift package: the snapshot
  opened with CryptoKit, matching, TOTP, the passkeys and the pending
  file), is tested with `swift test`, against vectors the app's Dart code
  seals (`tom_secrets_ui`'s `autofill_test.dart`: the snapshot, the
  passkeys' keys and a pending file). Dart opens the pending file the kit
  seals, `pending_swift_vector.json`, written with
  `TSM_UPDATE_VECTORS=1 swift test`.
- The extension target is in `Runner.xcodeproj` but not embedded in the
  app: its entitlements (the AutoFill credential provider, the App Group,
  the keychain access group) need the Apple Developer team's provisioning
  profile (DP-176). `Runner/Configs/Autofill.xcconfig` names the team
  (`TSM_TEAM_ID`, empty) and derives the groups from it; without it the
  app says AutoFill is not configured.
- Compile it unsigned:
  `xcodebuild -project macos/Runner.xcodeproj -target TomSecretsAutofill
  CODE_SIGNING_ALLOWED=NO build` (`ci.sh :analyze` does).
- **Linux** needs `libayatana-appindicator3-dev` (the tray) and
  `libsecret-1-dev` (the keychain).
- **Windows** needs Visual Studio 2022 Build Tools with "Desktop development
  with C++" and the ATL component: `flutter_secure_storage_windows` and
  `flutter_local_notifications_windows` include ATL headers and C++20
  coroutines, which the 2019 tools without ATL refuse.

## Configuration

| Setting | Effect |
| --- | --- |
| `--hidden` | start in the tray without showing the window (the login item passes it) |
| `TSM_DATA_DIR` | the data directory (default `~/Library/Application Support/TomSecretsManager`, `%LOCALAPPDATA%\TomSecretsManager`, `~/.local/share/tom-secrets-manager`) |
| `TSM_RUNTIME_DIR` | where the running service is found |
| `TSM_SERVICE` | the service executable to start, instead of the one beside the app |
| `TSM_LOGIN_ITEM=off` | a development run does not register its build as a login item, and removes such a registration made before |

Everything else is set in the app: its Settings screen (see the
[user guide](doc/user_guide.md#settings)).

## Limits

- Linux cannot keep the window out of screen capture.
- The macOS app is ad-hoc signed, not notarised: the first start needs
  Control-click › Open.
- The macOS AutoFill provider is in the team-signed build only; the
  ad-hoc signed build has none (Settings › Password AutoFill says so).
- Phase A is the desktop app; the mobile app, the browser extension and the
  relay are not built yet.

## Further documentation

- [User guide](doc/user_guide.md): installing, the First run wizard, the
  vault browser, system secrets, approvals, the import, keys, pairing,
  settings and troubleshooting.
- [`tom_secrets_ui`](../tom_secrets_ui/README.md): the screens and state.
- [`tom_secrets_desktop`](../tom_secrets_desktop/README.md): the desktop
  ports.
- [`tom_secrets_build`](../tom_secrets_build/README.md): the CI and the
  release build.

## Status

Version 0.1.0 (phase A). The app has no suite of its own: its screens are
tested in `tom_secrets_ui`, its host in `tom_secrets_desktop`, and the
assembled release by the smoke run of `ci.sh :release`.

## Licence

BSD-3-Clause ([`LICENSE`](LICENSE)); [`THIRD_PARTY.md`](../THIRD_PARTY.md)
lists what the app bundles.
