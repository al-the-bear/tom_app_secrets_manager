# Changelog

## 0.1.0

- The desktop implementations of `tom_secrets_ui`'s ports: the service host,
  tray, window, notifications, start at login, screen-capture exclusion,
  protected clipboard, preferences, files, the print path (`printing`) and
  one instance per user.
- A machine without `bootstrap.yaml` answers not set up; the first run
  writes into the data directory and the OS keychain.
- The service is looked for beside the app, then in the app's distribution
  (`tsm/bin`).
- Attaching removes the admin keys of services that are gone; stopping the
  service removes its key (`TomSecretsAdminKeyring`).
