# Changelog

## 0.1.0

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
