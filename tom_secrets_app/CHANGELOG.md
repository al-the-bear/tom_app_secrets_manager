# Changelog

## 0.1.2

- Imported fields keep their own labels (`tom_secrets_core` 0.2.28): no
  section prefix such as `Weitere Details · `.
- Attachments are shown in the app, from memory only: pictures (PNG, JPEG,
  GIF, WebP, BMP) in a viewer, text files (`.txt`, `.csv`, `.md`, keys,
  `.ovpn` profiles, any UTF-8 text) as selectable text; Save as… stays for
  every file.

## 0.1.1

- Vaults of any size: a save over 64 KiB and a vault over 1 MiB cross the
  admin endpoint as chunks (`tom_secrets_client` 0.2.19,
  `tom_secrets_service` 0.25.6), so a large import no longer hangs; a
  failed save is reported at once.

## 0.1.0

- The AutoFill provider signs in with passkeys and makes them (macOS 14,
  `ProvidesPasskeys`); a new passkey waits in the pending file until the
  app saves it into a vault.
- Auto-type and quick access: the host gets the desktop keyboard and
  hotkeys (`tomSecretsDesktopKeyboard`, `tomSecretsDesktopHotkeys`).
- The desktop app: one instance per user, the tray, start at login hidden,
  the window kept out of screen capture, over `tom_secrets_ui` and
  `tom_secrets_desktop`.
