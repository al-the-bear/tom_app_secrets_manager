# tom_secrets_mobile

> Part of the Tom Secrets Manager by Peter Nicolai Alexis Kyaw, BSD-3-Clause.

The Tom Secrets Manager's mobile app on iPhone, iPad and Android phones and
tablets: the composition root over `tom_secrets_ui`'s screens, with its own
adaptive shell and an in-app engine in place of the secrets service.

## Overview

A phone runs no secrets service and keeps no copy of a vault:

- **The vaults stay on GitHub.** At the unlock the app fetches the primary
  and the vaults it lists into memory; at the lock they are dropped. Without
  a connection a locked phone cannot open them: the unlock says so.
- **Sync while open.** Every minute the app looks for vaults whose refresh
  interval (15 minutes by default, 5 at least) is due, one conditional
  request each, and at every return to the foreground and on pull-to-refresh
  it looks at all of them; a branch another device moved is merged in. An
  edit is written to GitHub at once, merged with such a branch. When GitHub
  cannot be reached, the edit stays in memory, the vault shows "1 change not
  written to GitHub", and the next refresh that reaches GitHub writes it
  (merged three-way when the vault moved meanwhile); the lock asks first
  ("Write now" or "Discard"), since the phone keeps no copy.
- **Unlocked with biometrics.** The first unlock types the master password;
  the app then keeps the primary's composite key under Face ID, Touch ID or
  the fingerprint (never the password), and the next unlocks ask only for
  that. Settings turn it off.
- **Set up by pairing.** The desktop app's Pairing screen gives the phone the
  vaults' locators, key files, repository keys and a GitHub token of its
  own; the master password never travels.
- **System vaults are read-only** on a phone (BP-40).
- **iOS has no autofill** from this app: logins are shown and copied from it
  (TD-4). Android's Autofill service is its own package.

The app locks after 30 seconds in the background (settings: at once, 1 or
5 minutes). A copied value is kept off other devices (iOS: local only, no
Universal Clipboard), marked sensitive (Android 13 hides it from previews),
and cleared after 30 seconds. Android keeps the window out of screenshots,
recordings and the recent-apps thumbnail (`FLAG_SECURE`); iOS covers it
while the app is not active, so the app switcher shows no entry.

The package is an application: nothing imports it outside its tests. Its
map is the [user guide](doc/user_guide.md).

## Layouts

- **Below 600 dp:** one pane at a time (vaults, entries, the entry) and a
  bottom bar: Vaults, Search, Generator, Settings.
- **600–900 dp:** the entry list and the entry side by side, a navigation
  rail.
- **Above 900 dp:** the desktop's three panes (tree, list, entry), a
  navigation rail.

The layout follows the window's width, so iPad Split View and foldables
switch on their own.

## How it is built

- `lib/src/mobile_engine.dart`: the engine, the admin protocol answered
  in-process over `tom_secrets_service`'s vault set and its GitHub opener
  without an offline cache; the saves GitHub could not take yet.
- `lib/src/mobile_setup.dart`, `lib/src/setup_screen.dart`: the setup, what
  a pairing delivered into the keychain and the preferences, or a primary
  set up by hand.
- `lib/src/mobile_shell.dart`, `lib/src/mobile_settings_view.dart`: the
  shell and the settings.
- `lib/src/mobile_lifecycle.dart`: the refresh and the background lock.
- `lib/src/mobile_keychain.dart`, `lib/src/mobile_ports.dart`: the keychain
  (`tom_biometric_storage` without a check), the preferences file, the
  clipboard channel, the profile expiry.
- `lib/src/mobile_app.dart`, `lib/main.dart`: the composition.
- `android/app/src/main/`: `FlutterFragmentActivity` (the biometric prompt
  needs it), `FLAG_SECURE`, the sensitive clipboard, no backup; the release
  signing in `android/app/build.gradle.kts`.
- `ios/Runner/`: the local-only expiring pasteboard, the privacy cover, the
  profile expiry, the Face ID and local-network texts.

## Building and running

```text
flutter run                             # a connected device or a simulator
flutter build apk --release             # Android, signed with the release key
flutter build ios --release             # iOS, signed with the personal team
```

The app installs locally, without an app store (DP-204): the Android APK
from `tom_binaries` (built and signed by `tom_secrets_build`'s `ci.sh
:mobile`), the iOS build from Xcode under the free personal team (re-signed
every 7 days; from two days before the profile expires, the app shows the
date it stops starting). The iOS simulator does not enforce the biometric
access control of the keychain item; the Face ID unlock is checked on a
device.

## Testing

```text
testkit :test
```

The tests run the engine and the app against a fake GitHub
(`tom_github_api`'s `FakeGitHubServer`) with demo vaults (Argon2id at 1 MiB),
an in-memory keychain and gated store: the unlock with the key file from the
pairing, an edit written and another device's change merged, the system
vault refused, the OS unlock's composite key, no network, a save kept while
GitHub is out of reach and written (merged) when it is back, the phone and
tablet layouts, the biometric unlock and its switch, the background lock,
the clipboard timeout, the setup reset, the reinstall banner. Demo data
only.

## Limits

- No offline copy: a locked phone without a connection cannot open a vault.
- Only `github:` vaults (a `file:` vault on a desktop disk is not reachable).
- The phone approves nothing and is no approval link's peer: it receives no
  trust material from the pairing.
- The pairing is typed (address and code); the desktop's LAN announcement is
  not looked for, and there is no QR code yet.
- The GitHub App sign-in (device flow) is a desktop feature; the phone uses
  the token the pairing gave it.
