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
- The force-push question: a vault whose branch on GitHub was rewritten
  without a compaction is named on its header and the Status screen, and a
  dialog takes the file on GitHub or merges this copy over it.
- Import, keys and reminders: the Import screen (1Password 1PUX/CSV,
  Enpass JSON/CSV: mapping, preview, import, report, deleting the export),
  the Keys screen (every key with its date, a vault's keys' due date, the
  DP-85 rotation ages), the reminder banner with its snooze and the daily
  notification, and the warning when an offline copy is over a week old.
- Clients and settings: the approval prompt (shown on top, a notification
  while the window is closed), the Clients screen (approvals, the allow list
  with Revoke, pre-approval, the approval code, the audit log) and the
  Settings screen (the device settings through `settings.get` /
  `settings.set`, command-line approvals, screen capture, start at login,
  stopping the service, the shared `tsm.config`).
- The First run wizard: the primary vault created or opened, local or in a
  GitHub repository, its key file and outer encryption, the machine's
  settings; then the service started and unlocked.
