# Changelog

## 0.1.0

- The typed SSH key: the entry editor's "SSH key" type with its section
  (type and bits, fingerprint, the public key with Copy; "Generate an
  Ed25519 key", "RSA 4096" for a tool that needs RSA, "Choose a key file…",
  replacing after a confirmation), the type in the New entry menu and the
  type filter; `TomSecretsSession.generateSshKey` and `setSshKeyFile`; at
  every load the notes holding a private key in a writable vault become
  `ssh-key` entries and the vault is saved (`migratedSshKeys`).
- The First run wizard by pairing takes "This machine's approval link"
  (optional, checked: `host:port`, never every interface): the giving
  machine is told it with the pairing and opens the link, and the machine
  is set up with it as its device setting `approvalLink`.
- New vault (`tomSecretsShowNewVaultDialog`, `TomSecretsSession.createVault`,
  `TomSecretsNewVaultSpec`): a further vault beside the primary, from the
  vault browser, the Environments screen (a configured file without keys
  created as a system vault in its environment) and the Import screen ("Into
  a new vault…"); its kind and environment, its place (beside the primary,
  another GitHub repository, a file), its keys (a password given or
  generated and kept in the primary, no key file, the primary's or a new one)
  and its outer encryption (a new repository key or one the repository
  uses), created through the service's `vault.create`.
- A paired host's prompts (passed on by this machine's service, their ids
  qualified `<host>/<approvalId>`) sit in the same prompt list beside this
  host's and are answered the same way.
- Pairing on the LAN: the `TomSecretsPairingDiscovery` port
  (`TomSecretsHost.pairingDiscovery`); the Pairing screen announces its open
  window as `_tsm-pair._tcp` with the code's number, and the First run
  wizard finds it by the code alone when the address is left empty (the
  address on this machine's network chosen; none or several found, or no
  mDNS: the address is asked for).
- The Tom UI modules from pub.dev (`tom_ui_support`, `tom_host_ui`,
  `tom_credentials_ui`, `tom_sync_ui`) in place of `tom_reusable_ui` by
  path; no `pubspec_overrides.yaml` any more.
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
- Setting a new desktop up by pairing: the First run wizard's "Pair with
  another desktop" takes the other machine's address and code, receives
  the pairing (nothing stored), shows what it gave, takes the master
  password and sets the machine up from it (`TomSecretsFirstRun.runPaired`),
  the protection step left out; the last step's "Pair another desktop"
  opens the Pairing screen (`tomSecretsShowPairing`). The Pairing screen
  shows IPv6 addresses in brackets and tells a bundle the device refused.
- The First run wizard shows the errors it reports through `fail` (they
  were cleared at once).
- The First run wizard: the primary vault created or opened, local or in a
  GitHub repository, its key file and outer encryption, the machine's
  settings; then the service started and unlocked.
