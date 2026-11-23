# Changelog

## 0.1.0

- AutoFill passkeys (macOS 14): `ASPasskeyCredentialIdentity` beside the
  password identities; the pending file of the passkeys the extension made,
  read with the lasting pending key and replaced only when unchanged
  (coordinated with the extension).
- Auto-type's keyboard through FFI, no plugin: `TomSecretsMacKeyboard`
  (`CGEventPost`, the Accessibility API and its prompt, secure input),
  `TomSecretsWindowsKeyboard` (`SendInput`, `GetWindowTextW`),
  `TomSecretsX11Keyboard` (XTest, `_NET_WM_NAME`; Wayland refused,
  `tomSecretsX11Unavailable`); `tomSecretsDesktopKeyboard`.
- Global hotkeys with this package's own platform code (DP-32): macOS
  Carbon `RegisterEventHotKey`, Windows `RegisterHotKey` on
  `tom_secrets_desktop/hotkeys` (`TomSecretsChannelHotkeys`), X11
  `XGrabKey` through FFI (`TomSecretsX11Hotkeys`);
  `tomSecretsDesktopHotkeys`.
- Notification buttons (`TomSecretsNotifier.notify`'s `actions`): macOS
  categories registered at the start (`actionCategories`), Linux and Windows
  actions; a button runs its action, a click the notification's.
- The macOS AutoFill port (`TomSecretsMacAutofill`, channel
  `tom_secrets_desktop/autofill`): the provider's state, the snapshot key
  into the keychain under Touch ID, the snapshot into the App Group
  container, removal, the QuickType identities, System Settings opened.
- `TomSecretsSingleInstance` passes the entry a later launch names
  (`--show-entry`, the browser host's `openApp`) to the running app;
  `TomSecretsDesktopServiceHost.browserHostExecutable`, the browser host
  beside the service.
- The OS unlock: `tomSecretsDesktopOsUnlock()` (Touch ID on macOS, Windows
  Hello on Windows, none on Linux) over `tom_biometric_storage`'s
  `TomBiometricGatedSecretStore`; `TomSecretsAdminClientChannel.unlockWithBundle`.
- `TomSecretsDesktopSessionEvents`: the screen lock and sleep from this
  package's own code (`tom_secrets_desktop/session`: macOS distributed
  notifications and NSWorkspace, Windows `WM_WTSSESSION_CHANGE` and
  `WM_POWERBROADCAST`).
- Start at login on Windows and Linux is this package's own code (the `Run`
  key through `win32_registry` 3, an XDG autostart entry) in place of
  `launch_at_startup`, which holds `win32` 5.
- `TomSecretsBonsoirPairingDiscovery` moved to `tom_secrets_ui`, which the
  mobile app shares; this package no longer depends on `bonsoir`.
- `tom_credentials_ui` and `tom_host_ui` from pub.dev in place of
  `tom_reusable_ui` by path; no `pubspec_overrides.yaml` any more.
- The desktop implementations of `tom_secrets_ui`'s ports: the service host,
  tray, window, notifications, start at login, screen-capture exclusion,
  protected clipboard, preferences, files, the print path (`printing`),
  opening web pages (`url_launcher`) and one instance per user.
- A machine without `bootstrap.yaml` answers not set up; the first run
  writes into the data directory and the OS keychain.
- The service is looked for beside the app, then in the app's distribution
  (`tsm/bin`).
- Attaching removes the admin keys of services that are gone; stopping the
  service removes its key (`TomSecretsAdminKeyring`).
