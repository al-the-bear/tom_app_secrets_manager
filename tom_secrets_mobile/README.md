# tom_secrets_mobile

> Part of the Tom Secrets Manager by Peter Nicolai Alexis Kyaw, BSD-3-Clause.

The Tom Secrets Manager's mobile app on iPhone, iPad and Android phones and
tablets: the composition root over `tom_secrets_ui`'s screens, with its own
adaptive shell and an in-app engine in place of the secrets service.

## Overview

A phone runs no secrets service and keeps no copy of a vault:

- **The vaults stay on GitHub.** At the unlock the app fetches the primary
  and the vaults it lists into memory (the vault list shows each fetch's
  size); at the lock they are dropped. Without a connection a locked phone
  cannot open them: the unlock says so and tries again by itself every 15
  seconds for 10 minutes, so it opens once the network is back.
- **Vaults in Files.** Settings › "Add a vault from a file" takes a KDBX
  file from the document picker (e.g. iCloud Drive; Android's Storage Access
  Framework): it is read into memory at the unlock and written back on save,
  merged when it changed there meanwhile; the app keeps no copy. It is
  listed in the primary (its password kept there, as every vault's) under
  `file:/tsm-document/<device>/<file name>`, which only this phone can
  reach: other devices list it as not reachable.
- **Sync while open.** Every minute the app looks for vaults whose refresh
  interval (15 minutes by default, 5 at least) is due, one conditional
  request each, and at every return to the foreground and on pull-to-refresh
  it looks at all of them; a branch another device moved is merged in. An
  edit is written to GitHub at once, merged with such a branch. When GitHub
  cannot be reached, the edit stays in memory, the vault shows "1 change not
  written to GitHub", and the next refresh that reaches GitHub writes it
  (merged three-way when the vault moved meanwhile); the lock asks first
  ("Write now" or "Discard"), since the phone keeps no copy.
- **In the background** (DP-131, DP-151): while the process lives and the
  vaults are still held (until the background lock), the same look goes on
  read-only. Another device's change comes into the copies in memory;
  nothing is written, neither to GitHub (an edit that waits is written at
  the return) nor to the device (a rotation's new key reaches the keychain
  at the next refresh in the foreground). Android keeps a backgrounded
  process running until it ends it; iOS suspends it within seconds, so
  there the look waits for the return.
- **Unlocked with biometrics.** The first unlock types the master password;
  the app then keeps the primary's composite key under Face ID, Touch ID or
  the fingerprint (never the password), and the next unlocks ask only for
  that. Settings turn it off.
- **Set up by pairing.** The phone scans the desktop's QR code (or the code
  is typed, found on the same network by the desktop's announcement, the
  address typed over the VPN), and the desktop app's Pairing screen gives
  the phone the
  vaults' locators, key files, repository keys and a GitHub token of its
  own; the master password never travels.
- **System vaults are read-only** on a phone (BP-40).
- **Shared vaults** (phase C) open like any vault the primary lists. When
  another member re-keyed one (a member removed), the next unlock reads its
  recipients file (`vault.recipients`), opens it with the member key from
  the primary and writes the new keys into the primary on GitHub. Creating,
  joining and changing members happen in the desktop app (BP-32).
- **Shares** (single-entry exports, phase C) are received, never sent
  (BP-32): Settings › "Shares" imports one pasted, scanned or opened; the
  engine answers `inbox.list`, `inbox.read` and `inbox.delete`, so the
  packages in the user's inbox folders of shared vaults are found at each
  unlock and refresh (a banner names them), imported and deleted, and
  packages older than 30 days deleted; `inbox.put` is refused. A shared
  vault whose mailbox is a relay server is read on the relay instead, with
  the member keys' proof, and its packages deleted there.
- **Guided rotations** (phase C, part-key-rotation): the phone is a device
  like the desktops. At each unlock, refresh and save of the primary its
  engine takes the next keys a guided rotation wrote into the primary: the
  primary's own next keys into the keychain beside its keys
  (`<handle>.next`), the ids of the keys it holds into its device record
  (`tomSecretsTakeNextKeys`), so the desktop's Keys screen stops listing it
  as missing; until it unlocks once, it is listed. After the desktop
  switched the primary, the refresh and the unlock open it with those next
  keys and keep them; a repository key rotated alone is taken up once the
  file has its slot and the old one dropped after the finish. Starting,
  switching and finishing a rotation is the desktop app's.
- **Attachments** are added from the document picker and opened in another
  app through the share sheet (the shared copy is removed when the sheet
  closes on iOS, at the next share or start on Android).
- **Reminders.** Two weeks before this phone's GitHub token expires (the
  date the pairing delivered, or the one GitHub reports) a banner leads to
  Settings; a refused token tells, also on the unlock screen, to set the
  device up again ("Set this device up again": pair, or by hand).
- **A vault too heavy for the phone** (Argon2 asking more than a quarter of
  its memory) is refused at the unlock with a message, before the key
  derivation could exhaust the memory.
- **Android's Autofill service** (part-os-integration, DP-175,
  `TomSecretsAutofillService`): apps and browsers get the logins of the
  personal and shared vaults (never a system vault's). A request is
  answered at once with one locked response, "Unlock Tom Secrets Manager"
  (an inline chip in keyboards that show them, Android 11+). Choosing it:
  - while the app runs unlocked, BiometricPrompt (the fingerprint or the
    screen lock), then the logins from the app's memory
    (`AutofillAuthActivity` asks it over `tom_secrets_mobile/autofill`);
  - otherwise the app's own unlock on an engine of its own
    (`AutofillUnlockActivity`, Dart entry point `autofillMain`): the vaults
    fetched from GitHub into memory, the logins handed back, everything
    dropped when it closes; without network it says so.

  Matching: a browser's page by the browser extension's rules, an app by
  `androidapp://<package>` in the entry's URLs; a package match is verified
  against the Digital Asset Links of the entry's web domain with the
  requesting app's signing certificate, else marked "unverified app". A
  login signed in with that the vaults do not hold is offered for saving
  (`onSaveRequest`): the app opens with it under Proposals, saved into a
  personal or shared vault once confirmed. Settings › "Autofill service"
  turns it on.
- **Android's Credential Manager provider** (part-os-integration, DP-120,
  Android 14+, `TomSecretsCredentialService`): the passkeys of the personal
  and shared vaults, never a system vault's.
  - **Listing.** A sign-in is listed at once from the passkey identities:
    the relying party, user name and credential id, never a key. The app
    hands them over after every unlock and change, and the provider keeps
    them in its no-backup files. A site with no identity gets "Unlock Tom
    Secrets", which lists its passkeys after the unlock.
  - **Answering.** The entry picked is answered as the Autofill service's
    are: by the running app after BiometricPrompt (`PasskeyActivity`), or
    by its own unlock (`PasskeyUnlockActivity`, Dart entry point
    `passkeyMain`).
  - **New passkeys.** A creation makes ES256 or Ed25519 by the site's
    order. It is refused when the site excludes a passkey held. The
    passkey is kept in the vault of the site's login, in that login or a
    new one (`TomSecretsMobileEngine.keepPasskey`), and written to GitHub
    before the site gets its answer.
  - **The caller is checked.** A browser on the privileged-browser
    allowlist names the page; the origin must be the relying party or
    below it, over https. The allowlist is
    `res/raw/privileged_browsers.json`, the list Google publishes for
    passkey providers. An app must be named, with its signing certificate,
    by the site's Digital Asset Links, and gets client data naming it.
    A caller that is not let in learns nothing of the vaults.
- **The health report** (part-password-manager, DP-39): Settings › Health
  opens `tom_secrets_ui`'s Health screen; the breach check runs while the
  app is open and unlocked, each run shown as a snack bar with "Turn off
  breach check"; its switch is in Settings.
- **iOS has no autofill** from this app: logins are shown and copied from it
  (TD-4).

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
- `lib/src/mobile_documents.dart`: the documents port and its channel, the
  `file:` vaults' opener (`TomSecretsDocumentOpener`) and which document
  each locator is, the attachments' files.
- `lib/src/mobile_kdf_guard.dart`: the Argon2 memory read from the KDBX 4
  header and checked before a vault is opened (`TomSecretsKdfGuardedOpener`).
- `lib/src/mobile_setup.dart`, `lib/src/setup_screen.dart`: the setup, what
  a pairing delivered into the keychain and the preferences, or a primary
  set up by hand.
- `lib/src/mobile_shell.dart`, `lib/src/mobile_settings_view.dart`: the
  shell and the settings.
- `lib/src/mobile_lifecycle.dart`: the refresh (read-only in the
  background) and the background lock.
- `lib/src/mobile_scanner.dart`: the camera's QR reader over
  `mobile_scanner` (AVFoundation on iOS, Google's ML Kit model bundled on
  Android; closed source, named in the repository's `THIRD_PARTY.md`).
- `lib/src/mobile_keychain.dart`, `lib/src/mobile_ports.dart`: the keychain
  (`tom_biometric_storage` without a check), the preferences file, the
  clipboard channel, the profile expiry.
- `lib/src/mobile_app.dart`, `lib/main.dart`: the composition.
- `android/app/src/main/`: `FlutterFragmentActivity` (the biometric prompt
  needs it), `FLAG_SECURE`, the sensitive clipboard, the documents (the
  Storage Access Framework with persisted permissions, the share sheet
  through a `FileProvider`), the physical memory, no backup; the release
  signing in `android/app/build.gradle.kts`.
- `ios/Runner/`: the local-only expiring pasteboard, the privacy cover, the
  documents (security-scoped bookmarks, NSFileCoordinator, the share sheet),
  the physical memory, the profile expiry, the Face ID, camera and
  local-network texts and the Bonjour service type (`_tsm-pair._tcp`).

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
the read-only refresh in the background (another device's change in
memory, nothing written to GitHub or the keychain until the return),
the clipboard timeout, the setup reset, the reinstall banner, the
desktop's QR code scanned (a fake scanner), the window found on the network
by the code (a fake discovery), a TOTP secret scanned; a file added as a
vault, written back and merged with a change made there, unreachable on
another device; an attachment added and shared; a too heavy vault refused;
the token reminder; the unlock retried once the network is back; the fetch
sizes (documents in memory); the Autofill service's matching, Digital Asset
Links (a fake site), the running app answering it, a submitted login
becoming a proposal, and the app as the service's own unlock; the passkey
provider's caller check, a sign-in signed, a passkey made, refused or kept
in a vault on GitHub, and the app as the provider's own unlock. Demo data
only. The camera itself is checked on a device.

The Autofill service's native side runs on an emulator or a device
(`android/app/src/androidTest`, UiAutomator against a login form in the test
APK's package: the locked response, the app's own unlock, the save request
opening the app with the login):

```text
cd android && ./gradlew app:connectedDebugAndroidTest
```

The user guide's screenshots (`doc/images/`, a phone at 390×844 and a
tablet at 1024×1366, both themes, the real fonts) are tests tagged
`screenshots`, which run only when they write the images:

```text
flutter test --tags screenshots --update-goldens test/screenshots
```

## Limits

- No offline copy: a locked phone without a connection cannot open a vault.
- A desktop's `file:` vault (a path on its disk) is not reachable from a
  phone, as a phone's file is not from a desktop.
- A phone does not re-key, move or create a vault: the desktop app does.
- The phone approves nothing and is no approval link's peer: it receives no
  trust material from the pairing.
- The GitHub App sign-in (device flow) is a desktop feature; the phone uses
  the token the pairing gave it.
- The Autofill service fills logins, the Credential Manager provider
  passkeys (Android 14 and later only); an app the system's package
  visibility hides gives no certificate, so its package matches stay
  "unverified app".
- The privileged-browser allowlist is a copy taken when the app was built:
  a browser added to Google's list later is treated as an app until the
  copy is refreshed.
