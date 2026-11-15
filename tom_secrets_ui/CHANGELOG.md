# Changelog

## 0.1.0

- The shell, the Unlock and claim screens, the vault browser (tree and list
  views), the entry editor with the password generator and TOTP, the Status
  view, and the controllers `TomSecretsServiceConnection` and
  `TomSecretsSession` over the host's ports.
- Overlays and system secrets: the overlay editor (the matrix, overlays
  created, edited and removed in place, "which value does … get?" step by
  step), the vault-aware and uniform views, the Environments screen (the
  keys across the files, the vaults this machine does not serve opened for
  editing through the service) and the Conflicts screen over `TomMergeView`.
- Clients and settings: the approval prompt (shown on top, a notification
  while the window is closed), the Clients screen (approvals, the allow list
  with Revoke, pre-approval, the approval code, the audit log) and the
  Settings screen (the device settings through `settings.get` /
  `settings.set`, command-line approvals, screen capture, start at login,
  stopping the service, the shared `tsm.config`).
- The First run wizard: the primary vault created or opened, local or in a
  GitHub repository, its key file and outer encryption, the machine's
  settings; then the service started and unlocked.
