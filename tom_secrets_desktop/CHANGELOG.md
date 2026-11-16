# Changelog

## 0.1.0

- `TomSecretsBonsoirPairingDiscovery`: the pairing discovery port over
  `bonsoir` (mDNS, `_tsm-pair._tcp`).
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
