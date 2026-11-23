# tom_secrets_desktop

> Part of the Tom Secrets Manager by Peter Nicolai Alexis Kyaw, BSD-3-Clause.

The desktop host of the Tom Secrets Manager's manager app on macOS, Windows
and Linux: the implementations of `tom_secrets_ui`'s ports.

## Overview

`tom_secrets_ui` holds the screens and asks its host for everything a
platform decides, through the ports of `TomSecretsHost`. This package fills
them on the desktop: it finds, starts, attaches to and claims the user's
secrets service, puts the app in the tray or menu bar, hides the window on
close, shows notifications, registers start at login, keeps the window out
of screen capture, opens file and print dialogs and web pages, and announces
a pairing window on the LAN. Each third-party plugin sits behind a port, so
it can be swapped (DP-32); the parts no plugin offers (capture exclusion,
the macOS login item, the macOS clipboard markers) are this package's own
platform code.

```text
 tom_secrets_app
   |
   |-- TomSecretsHost(...)  <- tom_secrets_desktop fills every port
   |                            (plugins + macos/ Swift + windows/ C++)
   '-- TomSecretsApp(host)  <- tom_secrets_ui
```

## Getting it

The package is not published (`publish_to: none`); the app of this
repository takes it by path:

```yaml
dependencies:
  tom_secrets_desktop:
    path: ../tom_secrets_desktop
```

It needs Flutter 3.38 or later. The platform build requirements (Visual
Studio components on Windows, the tray and keychain libraries on Linux) are
the app's, listed in [`tom_secrets_app`](../tom_secrets_app/README.md).

## The ports

- **Service host**: `TomSecretsDesktopServiceHost`: the runtime directory of
  this user's service; starting it (`tomSecretsStartService`, the service
  executable from `TSM_SERVICE` or beside the app, `bootstrap.yaml` in the data
  directory); attaching with the admin key kept in the OS keychain under tsm's
  handle (`tsm.admin.<start>`, service `tom-secrets-manager`, through
  `tom_core_storage`'s `TomDesktopSecretStore`), so the app and tsm share it;
  claiming with the master password; a machine without `bootstrap.yaml` answers
  not set up, and its first run (`TomSecretsFirstRun`) writes into the data
  directory (`TSM_DATA_DIR`, else the platform's) and the OS keychain.
- **AutoFill** (macOS): `TomSecretsMacAutofill` (`tomSecretsDesktopAutofill()`)
  over this package's channel `tom_secrets_desktop/autofill`: whether the
  build has the AutoFill provider and it is on in System Settings
  (`ASCredentialIdentityStore.getState`), the snapshot key into the
  data-protection keychain's shared access group (`biometryCurrentSet`, or
  `userPresence` on a Mac without Touch ID), the sealed snapshot into the App
  Group container (atomically), removal, the QuickType identities
  (passwords, and on macOS 14 the passkeys as `ASPasskeyCredentialIdentity`),
  and System Settings opened. The pending passkeys the extension made
  (`readPending` with the lasting pending key, made at the first unlock;
  `replacePending`, coordinated with the extension's writes and refused
  when the file changed since it was read) are saved by `tom_secrets_ui`. The groups come from the app's Info.plist
  (`TSMAutofillAppGroup`, `TSMAutofillKeychainGroup`); null on Windows and
  Linux.
- **Tray**: `TomSecretsPluginTray` over `tray_manager`: the macOS menu bar
  (template images), the Windows notification area (ICO), the Linux tray
  (StatusNotifierItem through AppIndicator); the icons in `assets/tray/`
  (`tool/make_tray_icons.py` draws them).
- **Window**: `TomSecretsPluginWindow` over `window_manager`: closing hides the
  window (the app stays in the tray, DP-30), or minimises it where no tray is.
- **Notifications**: `TomSecretsPluginNotifier` over
  `flutter_local_notifications`.
- **Start at login**: `TomSecretsDesktopLoginItem`, this package's own code with
  `--hidden`: macOS through `SMAppService` (macOS 13+), Windows through the
  user's `Run` key, Linux through an XDG autostart entry
  (`~/.config/autostart/<app>.desktop`).
- **OS unlock**: `tomSecretsDesktopOsUnlock()`: `tom_biometric_storage`'s
  `TomBiometricGatedSecretStore` — Touch ID on macOS (gate-only in an ad-hoc
  signed build: the item in the login keychain behind LocalAuthentication;
  key-bound in the data-protection keychain once team-signed), Windows Hello
  (key-bound: the AES key exists only after Hello has signed); null on Linux.
- **Screen lock, sleep**: `TomSecretsDesktopSessionEvents`, this package's own
  code: macOS `com.apple.screenIsLocked` and NSWorkspace's will-sleep, Windows
  `WTS_SESSION_LOCK` and `PBT_APMSUSPEND`.
- **Screen capture**: `TomSecretsPlatformCaptureGuard`, this package's own code:
  `NSWindow.sharingType = .none` on macOS,
  `SetWindowDisplayAffinity(WDA_EXCLUDEFROMCAPTURE)` on Windows (10 2004+);
  Linux cannot exclude a window (DP-33).
- **Pairing discovery**: `tom_secrets_ui`'s `TomSecretsBonsoirPairingDiscovery`
  (shared with the mobile app): Bonjour on macOS (`NSBonjourServices` and
  `NSLocalNetworkUsageDescription` in the app's `Info.plist`), DNS-SD on
  Windows, Avahi over D-Bus on Linux (`avahi-daemon` must run).
- **Clipboard**: `tomSecretsDesktopClipboard()`: `tom_host_ui`'s
  `TomDesktopClipboardPort`, its macOS half (the concealed and transient
  pasteboard markers) in this package's code.
- **Preferences, files**: `TomSecretsFilePreferences` (`app-preferences.json` in
  the data directory, never synced), `TomSecretsDesktopFiles` (`file_selector`:
  key files, attachments, the First run's vault file and the copies of its new
  keys).
- **Print path**: `TomSecretsDesktopPrinter` over `printing`: the system print
  dialog for the emergency sheet (on Windows and Linux `printing` bundles
  PDFium, which its build downloads).
- **Web pages**: `tomSecretsDesktopOpenUrl` over `url_launcher`: GitHub's token
  pages in the system browser (`https` only).
- **One instance**: `TomSecretsSingleInstance`: a second launch brings the
  window to the front (`app.port` in the data directory).
- **Auto-type's keyboard** (DP-41): `tomSecretsDesktopKeyboard()`, FFI into
  the OS, no plugin: `TomSecretsMacKeyboard` (`CGEventPost` with Unicode
  text, the Accessibility API for the permission, its prompt and the active
  window's title, Carbon's `IsSecureEventInputEnabled`),
  `TomSecretsWindowsKeyboard` (`SendInput` with `KEYEVENTF_UNICODE`,
  `GetWindowTextW`), `TomSecretsX11Keyboard` (XTest, a spare keycode for a
  character the layout lacks, `_NET_WM_NAME`; on Wayland one that says why
  not).
- **Global hotkeys**: `tomSecretsDesktopHotkeys()`, this package's own code
  (DP-32; the hotkey plugins build through CocoaPods): Carbon
  `RegisterEventHotKey` on macOS and `RegisterHotKey` on Windows
  (`TomSecretsChannelHotkeys`), `XGrabKey` through FFI on X11
  (`TomSecretsX11Hotkeys`, its events read every 100 ms); none on Wayland.

The platform code is in `macos/` (Swift, the channels
`tom_secrets_desktop/capture`, `/clipboard`, `/login`, `/session`,
`/autofill`, `/hotkeys`) and `windows/` (C++, `/capture`, `/session`,
`/hotkeys`).

## Usage

The app's composition root fills the host from this package (shortened from
`tom_secrets_app/lib/main.dart`):

```dart
final window = await TomSecretsPluginWindow.create(
  title: 'Tom Secrets Manager',
  hidden: false,
  hideOnClose: true,
);
const files = TomSecretsDesktopFiles();
final host = TomSecretsHost(
  service: TomSecretsDesktopServiceHost(),
  tray: TomSecretsPluginTray(),
  window: window,
  captureGuard: TomSecretsPlatformCaptureGuard(),
  preferences: await TomSecretsFilePreferences.open(
    File('<data directory>/app-preferences.json'),
  ),
  keyFiles: files,
  files: files,
  printer: const TomSecretsDesktopPrinter(),
  openUrl: tomSecretsDesktopOpenUrl,
  clipboard: tomSecretsDesktopClipboard(),
  pairingDiscovery: const TomSecretsBonsoirPairingDiscovery(),
);
runApp(TomSecretsApp(host: host));
```

## Configuration

- `TSM_DATA_DIR`: the data directory (`bootstrap.yaml`, `app-preferences.json`,
  `app.port`); default the platform's
- `TSM_RUNTIME_DIR`: the runtime directory where the running service is found
- `TSM_SERVICE`: the service executable to start, instead of the one beside the
  app

The admin key is kept in the OS keychain under the service name
`tom-secrets-manager`, where `tsm` finds it too.

## Limits

- Linux cannot keep a window out of screen capture.
- On Linux the tray needs a StatusNotifierItem host (AppIndicator); without
  one the app has no tray and the window minimises instead of hiding.
- Pairing discovery on Linux needs `avahi-daemon` running; without it the
  other machine types the address.
- Start at login on macOS needs macOS 13 or later.
- Auto-type needs the Accessibility permission on macOS; on Windows it
  cannot type into a program running as administrator; on Linux it needs an
  X11 session and `libxtst6` (Wayland: no auto-type and no global hotkeys).
- The AutoFill port answers "not configured" in a build without the Apple
  team (no App Group, no keychain access group).

## Testing

```text
flutter test
```

The service host's tests run the real service in-process on demo vaults; the
others check one instance, the preferences file, the capture guard per
platform and the tray assets.

`tool/demo_installation.dart <folder> [<app executable>]` writes a demo
installation (a primary and a team vault under demo passwords, demo entries,
a bootstrap naming the app) for trying the app by hand; its header says how
to start the service and the app on it.

## Further documentation

- [`tom_secrets_ui`](../tom_secrets_ui/README.md): the ports and the screens
  they serve.
- [`tom_secrets_app`](../tom_secrets_app/README.md): the app, its build
  requirements, and its user guide.

## Status

Version 0.1.0 (phase A). The suite runs with `flutter test` on the platform
it is started on; the capture guard's checks for the other platforms run
everywhere.

## Licence

BSD-3-Clause ([`LICENSE`](LICENSE)).
