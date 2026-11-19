# Changelog

## 0.1.0

- Quick access and auto-type (part-app, part-password-manager, DP-41):
  `TomSecretsQuickAccess` (the popup from a global hotkey or the tray, the
  global auto-type hotkey), `TomSecretsQuickAccessDialog`,
  `TomSecretsAutoTyper` over the host's `TomSecretsKeyboard`, the
  `TomSecretsHotkeys` port and `TomSecretsHotkey`; the entry editor's
  Auto-type section; Settings › Auto-type and quick access; the tray's
  Quick access; `TomSecretsHost.keyboard`, `.hotkeys`, `.macOS`.
- The other imports and the exports (part-password-manager, DP-40): the
  Import screen reads Bitwarden JSON (asking a protected export's
  password), the browsers' CSVs and KeePass files (as a group or merged,
  `TomSecretsSession.importKdbxAsGroup` / `importKdbxMerged`), telling a
  JSON or CSV apart by its content (`tomSecretsGuessImportFormat`);
  `tomSecretsReadExport` is asynchronous. The Export dialog
  (`tomSecretsShowExportDialog`, `tomSecretsExport`) from a vault's or
  group's menu: KDBX under a new password, CSV, Bitwarden JSON, with the
  plaintext warning.
- The Health screen and the breach check (part-password-manager, DP-39,
  DP-179): `TomSecretsHealthView` in the rail, `TomSecretsHealth` (the report
  over the open vaults, the breach check on by default: new and changed
  passwords at once, all once a week, each run on `runs`), the host bridge's
  notification with "Turn off breach check", the switch in Settings › This
  app and the entry editor's "Check the password against known breaches";
  `TomSecretsNotifier.notify` takes `actions`
  (`TomSecretsNotificationAction`); `TomSecretsHost.breachCheck`;
  `TomSecretsSession.indexRevision`.
- Password AutoFill on macOS (DP-50, DP-51): `TomSecretsAutofill` writes the
  sealed snapshot (`TomSecretsAutofillSnapshot`: AES-256-GCM, a key per
  unlock) of the personal and shared vaults' logins after every unlock,
  edit and sync while the provider is on, and the QuickType identities;
  Settings › Password AutoFill (the provider's state, the way to System
  Settings, the app's switch, QuickType); `TomSecretsHost.autofill`.
- The Proposals screen (BP-28, DP-43, DP-52).
- The browser integration (part-browser): Settings › Integrations ›
  Browsers switches each browser found for the user on and off (its
  native-messaging manifest naming the browser host,
  `tom_secrets_client`'s `TomSecretsBrowserHosts`); the start check repairs
  a manifest naming another host and says so. `TomSecretsHost.integrationPaths`
  carries `browserHostExecutable`. `TomSecretsEntryRequests`
  (`TomSecretsHost.entryRequests`, `--show-entry`): an entry asked for from
  outside is shown in the vault browser once its vault is open.
- For the mobile app (part-mobile): `TomSecretsStoreState.fetchedBytes` (the
  size of the last fetch, when the host reports it);
  `TomSecretsReminderBanner` (the keys-due banner, public, its open button
  named by the host); `TomSecretsHost.unlockFooter` (below the unlock form)
  and `attachmentsShare` (an attachment's save is a share); the unlock
  screen shows a refusal with reason `no_copy` as its host wrote it.
- Pairing by QR code (DP-56, DP-61): `TomSecretsPairingInvitation` (the
  window's addresses, port and code as `tsm-pair:<address>,…:<port>?code=…`,
  and the address nearest the scanning device), shown by the Pairing screen
  as a QR code (`TomSecretsQrCode`, over `qr`); `tomSecretsFindPairingWindow`
  (the window found on the LAN by the code's number, shared by the First run
  wizard and the mobile app); `TomSecretsBonsoirPairingDiscovery` moved here
  from `tom_secrets_desktop`. `TomSecretsCodeScanner` (`TomSecretsHost.scanner`):
  the entry editor's "Scan a QR code" for a TOTP secret.
- The hooks the mobile app fills (part-mobile): `TomSecretsHost.shell`
  (the unlocked screen, default the desktop's main shell),
  `systemVaultsReadOnly` (a system vault is read-only on this device, BP-40;
  `TomSecretsSession.readOnlyReason` says so), `clipboardClearAfter` (the
  clipboard timeout), and `TomSecretsOsUnlockHost.keepSaved` (while it
  answers true, every unlock with the master password keeps a saved item).
- The OS unlock (part-os-unlock, DP-68–DP-71, DP-181): `TomSecretsOsUnlock`
  keeps the primary's composite key and repository key in the host's gated
  store (`TomSecretsHost.osUnlock`) — a session item in lock mode (c), a
  saved one with "Remember the master password with Touch ID" (BP-37) — and
  unlocks the service with it (`unlockWithBundle`); the unlock screen tries
  it at once and offers the button; a re-keyed vault, a changed enrolment
  and a session item of an older start are forgotten, the password asked;
  "Lock completely" (tray) and a service stop forget the session. Settings:
  lock mode (c), the saved master password, the gate-only form named the
  weaker one, no OS unlock on Linux, "Lock when the system sleeps". The
  bridge locks the service at the screen lock in mode (c) and at sleep with
  `lockOnSleep` (`TomSecretsHost.sessionEvents`). The editing path opens and
  saves the primary with the composite key the service holds after an OS
  unlock. On `tom_secrets_core` ^0.2.8, `tom_secrets_client` ^0.2.9,
  `tom_core_storage` ^0.1.3.
- "Sign in with GitHub" on the Keys screen (`TomSecretsGitHubSignInSection`,
  part-key-rotation §3, DP-83): naming the GitHub App once (its client id
  into the primary), the device code shown and its page opened, the state
  (signed in as …, until when unused, sign in again), "Use a personal
  access token instead"; the Pairing screen shows how each device reaches
  GitHub and the revoke says what cuts it off there. The metadata writers
  keep the App's client id. On `tom_secrets_core` ^0.2.7.
- git's credential helper and the integrations (part-os-integration): the
  pick prompt ("A tool asks for a login": the host's logins, this time,
  always this login, none; `approve` with `pick`), Settings › Integrations
  (ssh using the agent with its host patterns, git asking the helper;
  `TomSecretsHost.integrationPaths`) and the check at every start that
  repairs a block naming another agent or helper. On `tom_secrets_client`
  ^0.2.8.
- The ssh-agent (protocol.md 7.6): the approval prompt of an SSH signature
  (the key, the destination host by its `known_hosts` names, the purpose;
  "Only for this host"; a confirmation answered for one signature), "Only
  when started by …" (`withParent`) for any lasting answer; the allow list
  and the audit log say agent grants and signatures in words; pre-approving
  an agent grant with its keys, hosts and forwarding, and an executable
  started by a parent; the entry editor says whether the agent serves a key
  and switches KeeAgent's confirmation; a vault's menu sets
  `tsm.ssh-confirm`. On `tom_secrets_core` ^0.2.6.
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
