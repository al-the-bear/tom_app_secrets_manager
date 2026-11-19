# Changelog

## 0.1.0

- Shared vaults (part-sharing): the engine answers `vault.recipients` by
  store, so the session takes up a shared vault's new keys after another
  member re-keyed it (`refreshSharedVaultKeys`) and writes them into the
  primary on GitHub; by location, `vault.recipients.set` and member changes
  stay the desktop app's.
- Takes `tom_secrets_service` 0.17.0: the vault openers pass the
  recipients file beside a vault on (`readBeside`, `writeBeside`, the
  re-key's `beside`); a file vault in the phone's Files has none and writes
  none (shared vaults live in repositories, part-sharing).
- The health report and the breach check (DP-39): Settings › Health opens
  the Health screen, Settings has the breach check's switch, each run shows
  a snack bar with "Turn off breach check"; `TomSecretsMobileApp.breachCheck`.
- Android's Autofill service (part-os-integration, DP-175): the locked
  response at once (inline in the keyboard on Android 11+); BiometricPrompt
  and the running app's memory, or the app's own unlock on its own engine
  (`autofillMain`) fetching the vaults; a browser page by the browser's
  rules, an app by `androidapp://`, Digital Asset Links verifying a package
  match ("unverified app" otherwise), never a system vault; a submitted
  login handed to the app as a proposal (the Proposals screen); Settings ›
  Autofill service; device tests in `android/app/src/androidTest`.
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
- `file:` vaults from the phone's Files (`TomSecretsDocumentOpener`): listed
  in the primary under `file:/tsm-document/<device>/<file name>`, read into
  memory, written back, merged when changed there; Settings lists every
  vault with its locator. Attachments from the document picker and to the
  share sheet. The GitHub token's reminder two weeks ahead and, on a refused
  token, "Set this device up again" on the unlock screen. The unlock retried
  by itself when the network returns. A vault whose Argon2 needs more than a
  quarter of the device's memory refused at the unlock
  (`TomSecretsKdfGuardedOpener`). The size of each fetch on the vault list.
