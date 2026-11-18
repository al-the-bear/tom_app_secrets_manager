# Changelog

## 0.1.0

- The mobile app on iOS, iPadOS and Android (part-mobile, DP-55–DP-59,
  DP-130): the vaults fetched from GitHub into memory at the unlock and
  dropped at the lock, synced while open (the refresh interval, 15 minutes by
  default and 5 at least; the foreground; pull-to-refresh), edits written to
  GitHub at once and merged with a branch another device moved; the
  biometric unlock after the first master password (the composite key under
  Face ID, Touch ID or the fingerprint); set up by pairing with the desktop
  app, or a primary by hand; system vaults read-only; phone and tablet
  layouts by width; the background lock, the clipboard timeout, the secure
  window (Android) and the privacy cover (iOS). A save GitHub cannot take
  stays in memory as a change not written and is written (merged) at the
  next refresh that reaches GitHub. The reinstall reminder two days before
  the iOS profile expires (DP-130). No iOS autofill (TD-4).
- Pairing by the desktop's QR code (DP-56) with the camera
  (`TomSecretsMobileCodeScanner` over `mobile_scanner`), or by the code
  alone on the same network (the desktop's `_tsm-pair._tcp` announcement);
  TOTP secrets scanned in the entry editor.
