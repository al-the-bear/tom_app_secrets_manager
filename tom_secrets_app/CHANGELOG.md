# Changelog

## 0.1.0

- The AutoFill provider signs in with passkeys and makes them (macOS 14,
  `ProvidesPasskeys`); a new passkey waits in the pending file until the
  app saves it into a vault.
- Auto-type and quick access: the host gets the desktop keyboard and
  hotkeys (`tomSecretsDesktopKeyboard`, `tomSecretsDesktopHotkeys`).
- The desktop app: one instance per user, the tray, start at login hidden,
  the window kept out of screen capture, over `tom_secrets_ui` and
  `tom_secrets_desktop`.
