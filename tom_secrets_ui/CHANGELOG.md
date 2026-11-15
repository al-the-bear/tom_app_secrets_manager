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
- Key rotation by hand: from the Keys screen, a vault's master password, its
  key file (new, added or removed) and for a `.tsmx` vault its repository
  key and outer cipher, across every vault of the repository under that
  key; the new keys go into the primary first, the vaults are saved
  re-keyed, the GitHub repositories' history is cut, and copies of the new
  key file and repository key are offered. A rotation whose re-keyed save
  failed is finished from a banner.
- The emergency sheet (BP-37): the vaults with their locators,
  repositories, formats and ciphers, a blank line for the master password,
  and every key file and repository key as a QR code with its key id;
  printed through the host's print path or saved as a PDF, offered in the
  First run wizard and after a key rotation.
- Renewing a GitHub token from the Keys screen: GitHub's new-token page
  opened filled in, the pasted token checked and kept by the service
  (`token.set`), the result, and the page where the old token is deleted.
- Adding or removing a vault's outer encryption from the rotate dialog: the
  vault moved to `.kdbx.tsmx` or `.kdbx` through the service (`vault.move`),
  under a new repository key or one its repository's other vaults use, the
  history cut, a copy of a new key and the emergency sheet offered.
- Rotating this device's approver and approval-link key pairs from the Keys
  screen (`keys.rotate`), with the hosts reached and not reached.
- The Pairing screen, giving side: the pairing window on this machine's LAN
  and VPN addresses for five minutes with its code, addresses, port and
  countdown; once the other device proved the code, the bundle chosen (the
  vaults the primary lists with their key files and repository keys, the
  shared configuration, a GitHub token pasted for that device), sent or
  declined; `pair.record` afterwards; the paired devices (`pair.list`) with
  Revoke (`pair.revoke`). Locking the app closes the window.
- The First run wizard: the primary vault created or opened, local or in a
  GitHub repository, its key file and outer encryption, the machine's
  settings; then the service started and unlocked.
