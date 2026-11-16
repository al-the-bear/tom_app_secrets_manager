# tom_secrets_ui

> Part of the Tom Secrets Manager by Peter Nicolai Alexis Kyaw, BSD-3-Clause.

The screens and state of the Tom Secrets Manager's manager app, shared by the
desktop app and (phase B) the mobile app.

## Overview

The package is the whole user interface of the manager app, without a
platform. A host (the desktop app today) implements its ports in a
`TomSecretsHost` (the secrets service, the tray, the window, notifications,
screen capture, files, printing, the clipboard, pairing discovery) and runs
`TomSecretsApp` with it. `TomSecretsApp` holds a `TomSecretsServiceConnection`
to the user's secrets service and shows the screen its phase calls for: the
First run wizard on a machine that is not set up, the connection, claim and
unlock screens, then the main shell with its rail of screens.

The vaults are opened in the app's memory from the copy the service holds,
through `tom_secrets_core` (the only way to KDBX); every change is saved
through the service against the revision read. Nothing here decides a
platform, and nothing here reads or writes a vault file directly.

```text
 tom_secrets_app (composition root)
   |-- tom_secrets_desktop (ports on macOS, Windows, Linux)
   '-- tom_secrets_ui (this package)
         |-- TomSecretsApp -> screens (lib/src/screens/)
         |-- state: connection, session, models (lib/src/state/)
         '-- ports: TomSecretsHost (lib/src/ports/)
               |
               v
         the secrets service (admin connection, protocol)
```

## Getting it

The package is not published (`publish_to: none`); the apps of this
repository take it by path:

```yaml
dependencies:
  tom_secrets_ui:
    path: ../tom_secrets_ui
```

It needs Flutter 3.38 or later (Dart 3.10). Its own dependencies come from
pub.dev (see [Dependencies](#dependencies)).

## Quick start

A host builds a `TomSecretsHost` and runs the app. The smallest host has the
service only (the shape tests use):

```dart
import 'package:flutter/material.dart';
import 'package:tom_secrets_desktop/tom_secrets_desktop.dart';
import 'package:tom_secrets_ui/tom_secrets_ui.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final host = TomSecretsHost.headless(TomSecretsDesktopServiceHost());
  runApp(TomSecretsApp(host: host));
  // The window shows "Connecting", then the First run wizard on a machine
  // that is not set up, or the unlock screen.
}
```

The desktop app's `lib/main.dart` (in
[`tom_secrets_app`](../tom_secrets_app/)) is the full composition: every port
filled from `tom_secrets_desktop`, and the First run wizard's last step
offering the import and the pairing.

## What it holds

| Part | What it does |
| --- | --- |
| `TomSecretsApp` | The root: the controllers provided to the widget tree, the screen the connection's phase calls for, the compact theme. |
| `TomSecretsServiceConnection` | The admin connection: attaching, starting and claiming the service, unlock and lock, `status`, the event stream (`locked`, `unlocked`, `store_state`, `unlock_needed`, `approval_needed`, `key_expiry`), a dropped connection; the waiting prompts (`prompts`, `TomSecretsApprovalPrompt`) and `approve` (a client token made by the app for an `always` that asked for one, protocol 7.4). |
| `TomSecretsSession` | The vaults open in the app's memory: the copy the service holds of each store (`vaultKeys`, then `vaultFile`, protocol 6.4), opened with its keys through `tom_secrets_core`; the search index; the selection; the tree/list and vault-aware/uniform switches (kept per device); the resolution model (`resolution`); overlays created and edited; conflicts settled field by field; the vaults the primary lists that this machine does not serve (`unserved`), opened for editing only through the service (`openUnserved`: `vaultKeys` and `vaultFile` naming the vault) and saved like every other; edits saved through the service (`save` against the revision read), a change from elsewhere read again; key rotation by hand (`rotateKeys`: the new keys into the primary, each affected vault saved re-keyed, the GitHub history cut with `compact` retention 0; `pendingRotations` / `finishRotations` for a re-keyed save that failed); everything dropped on `locked`. |
| `TomSecretsFirstRunWizard` | Opened when the machine is not set up (no service runs and the data directory holds no `bootstrap.yaml`). Step 1: create a primary vault or open one, on this computer or in a GitHub repository (the token entered through `showTomTokenDialog` and the repository checked through `withTomTokenFlow`, its expiry as GitHub reports it or entered); the master password (`TomKeyFields` with the key file when opening). Step 2: the key file and the outer encryption (XChaCha20-Poly1305 or AES-256-GCM), each optional, with a copy saved where the user chooses, and the emergency sheet printed or saved as a PDF. Step 3: the machine's name, default environment, the files it serves, the lock mode, where the device settings' key is kept. Then `tom_secrets_core`'s `TomSecretsFirstRun` writes the setup, the service is started and unlocked with the master password, and step 4 offers the import and the pairing the host provides (`TomSecretsHost.firstRunActions`; `tomSecretsShowPairing` opens the Pairing screen). Instead of step 1, "Pair with another desktop" takes the address and code the other machine's Pairing screen shows and this machine's name, receives the pairing (`tomSecretsReceivePairingForSetup`: fresh approval keys, nothing stored; with the address left empty the window is found on the LAN by the code's number, `tomSecretsPairingAdvertFor` and `tomSecretsPairingAddressFor`), shows what it gave and takes the master password; step 2 is left out, and the setup is `TomSecretsFirstRun.runPaired` (the keys and tokens in the keychain, the giving device recorded as approver and host in the trust material). |
| Unlock, claim, connection screens | The master password and key file (`TomKeyFields`); a store with a password of its own opened on the vault browser (BP-8); the warning before a claim sends the master password (DP-16); starting a service that is not running. |
| `TomSecretsMainShell` | The rail (Vaults, Environments, Conflicts with the count of conflicted entries, Clients with the count of waiting approvals, Keys with the count of keys due, Pairing, Import, Settings, Status); a banner while a key is due (Snooze until its next reminder step, Open Keys); a new approval prompt shown on top at once, one at a time; the top bar (search over every vault, tree/list, vault-aware/uniform, the sync status of the GitHub vaults, the approvals and key-expiry badges, lock) and the keyboard shortcuts (Cmd/Ctrl+F search, +L lock, +N new entry, +1 tree, +2 list, +S save in the editor). |
| `TomSecretsVaultBrowser` | The tree view (group tree, entry list, details) and the list view (vault, type and tag filters); overlay groups (`@host:…`) shown as the entry's overlays, not folders; multi-select move, tag, delete to the recycle bin; groups created, renamed and moved; an offline vault marked with its reason and age. In the vault-aware view a system vault's entry shows its key, the dimensions it is bound in and which clients read it and when (the grants of every host), a personal or shared vault's entry its login, URL and TOTP; the uniform view shows each of them the entry has (`tomSecretsEntryDetails`). |
| `TomSecretsEntryEditor` | Login, API token and secure note: title, user name, the password with the generator, URLs, TOTP with its countdown, notes, custom fields (protected or not), tags, expiry, attachments, "How clients name it" (the path reference and the `tsm.key`, checked for uniqueness in the vault), "Overlays…" opening the overlay editor, the history with Restore. Protected values are masked, revealed one at a time for 30 seconds and copied through the protected clipboard (cleared after 30 seconds). A vault served from its offline copy opens read-only. |
| `TomSecretsResolutionModel` | The open vaults as the service's resolver sees them: the primary's configuration (the dimensions in priority order), every vault as a store; the dimension values a matrix has rows for (hosts from the grants, the devices and the bindings; every platform; the configured environments); what a request gets, step by step (the request's values, every candidate kept with its rank vector or dropped with the binding that drops it, the answer: the shared entry, an overlay, another file, none, ambiguous); the clients granted an entry. |
| `TomSecretsOverlayEditor` | One entry and its overlays as a matrix: the shared entry, then per dimension one row per value with the value it gets (masked when protected) and where it comes from; a cell edited in place; a click on a row without an overlay of its own creates one (`@<dimension>:<value>/<groups>/<title>`, a copy of the shared entry) and edits it; an overlay removed with its menu; a row of a dimension the file is bound to edits the entry in that value's file. "Which value does … get?" takes qualifiers (`[env:prod,host:server1]`) and shows the resolution step by step; ambiguities in red. |
| `TomSecretsEnvironmentsView` | The keys (`tsm.key`) across the environments' files side by side, one column per served file and per vault not served that is open for editing; the vaults the primary lists that this machine does not serve offered to open (the service reads each from its location with its listed keys and writes its saves there, protocol 6.4), the configured files the primary lists no keys for named; a cell edited in place and saved, an empty cell creating the entry. |
| `TomSecretsConflictsView` | The entries with an unsettled conflict (`tsm.conflict`) and `TomMergeView` over their fields: the value the merge kept and the one it replaced (from the entry's history), masked when protected; keep one side or edit the result; confirming writes it, takes the field off the record (the last one clears it) and saves. |
| `TomSecretsApprovalPromptDialog` | Which host asks, who asks there (executable or interpreter and script, arguments, folder, parent, as that host's service measured them), which secrets (references and resolved entries), and the answer: once, always, always for a folder, never; covering the reference, the store or everything; pinned to the program file or not. Closes itself when the prompt ends elsewhere; Later leaves it under Clients. |
| `TomSecretsClientsView` | Approvals (the waiting prompts, answered from here), the allow list of every host (filtered by host, grouped by executable, script, folder, interpreter; last use, accepted or not, Revoke), pre-approving a client for any host (`grants.add`), the approval code (`approval.issue`, and for a lasting answer the grant, its subject named as the waiting host shows it), the audit log (by time, host, client, reference, outcome). |
| `TomSecretsSettingsView` | Each setting says whose it is. This machine (`settings.get` / `settings.set`): the files served, the default environment, the lock mode and its times, the approval timeout and the code's validity, the pull interval, the offline cache, the reminder period, the approval link; command-line approvals (DP-19). This app: screen capture (DP-33; Linux cannot exclude a window), start at login, stopping the service. Shared: `tsm.config` in the primary vault, checked before it is saved. |
| `TomSecretsImportView` | The export (1Password 1PUX or CSV, Enpass JSON or CSV; the format by extension, asked for a CSV), where each source vault goes (a vault and a group, so source vaults go to groups of one vault or to different vaults), archived items or not, the preview (`tomSecretsImport` dry run: counts per outcome, what the format loses, the largest attachments, every item), the import saved through the service (every vault read again when a save is refused), the report, and the offer to delete the export. Also opened by the First run wizard's last step (`tomSecretsShowImport`). |
| `TomSecretsKeysView` | Every key with a date (`keys`), soonest first: the GitHub tokens, the vaults' key files and repository keys, the approver and approval-link key pairs; its use, date, time left, reminding or expired; a vault's keys get a due date (the primary's `tsm.keys-due`, else the vault's entry Expires in the primary); the DP-85 rotation ages and reminder starts (device settings); every vault the primary lists with Rotate…, a banner that finishes a rotation whose re-keyed save failed, Renew… on each GitHub token, and Rotate… on this device's own approver and approval-link key pairs (`keys.rotate`: both together, the result naming the hosts reached over the approval link and those that take the key change from the vault). |
| `TomSecretsPairingView` | The giving side of a pairing (part-sharing), over `TomSecretsPairingModel`: "Pair a device" opens a `TomSecretsPairingWindow` on this machine's LAN and VPN addresses (`tomSecretsPairingAddresses`, or the host's `pairingAddresses`) for five minutes and shows the code, the addresses and port, the countdown and that macOS and Windows Defender Firewall ask once whether the app may accept connections; with the host's `pairingDiscovery` it announces the window on the LAN as `_tsm-pair._tcp` with the code's number and addresses, until the window closes. Once the other device proved the code: its name, the vaults the primary lists (the primary included or not) each with its key file and repository key from `vaultKeys`, the shared configuration, a GitHub token pasted for that device per repository (never this machine's own); Confirm sends the bundle with this device's public keys (`pair.identity`), Decline sends nothing. Then `pair.record` (the device as a host with its link key and address, as an approver when it sent an approver key, the key ids handed over) and the result; a wrong code, a window closed without a device and a decline each get their message. The paired devices (`pair.list`): name, platform, paired date, the key ids received, the key-pair dates, revoked or not, and Revoke (`pair.revoke`, the confirmation naming the keys to rotate). Leaving the screen or locking the app closes the window. |
| `TomSecretsReminders` | The keys the service reports due, the snooze per key until its next step, the once-a-day notification. |
| `TomSecretsEmergencySheet` | The emergency sheet of a primary vault (BP-37): every vault it lists with its locator, repository, format (`.kdbx` or `.kdbx.tsmx`) and outer cipher; a blank line for the master password; every key file and repository key once, with its key id (the `.keyx` Hash, the repository key's id) and a QR code holding the `.keyx` file's text or the key in base64. It is made from locators and keys only, never from a password; `toPdf` renders it to an A4 PDF (`pdf`). `TomSecretsSession.emergencySheet` makes it as the keys are now, `TomSecretsFirstRunModel.emergencySheet` for the primary being created. |
| `TomSecretsEmergencySheetOffer` | "Print the emergency sheet…" (the host's `TomSecretsPrinter`) and "Save it as a PDF…" (`TomSecretsFiles.save`), in the First run wizard's protection step and the rotation's result. |
| `tomSecretsShowRenewTokenDialog` | Renewing a vault repository's GitHub token (part-key-rotation §3): GitHub's new-token page opened filled in (`tomSecretsNewTokenUrl`: name, description, owner, expiry, Contents read and write and Metadata read, within GitHub's template limits; the repository is selected by hand, GitHub cannot preselect it), the pasted token sent to the service (`token.set`, which checks it and keeps it where the old one was), the result with its expiry, and GitHub's token list to delete the old one. |
| `tomSecretsShowRotateDialog` | Rotating a vault's keys by hand (part-key-rotation): a new master password (typed or generated), the key file kept, replaced or added, or removed, and for a `.tsmx` vault a new repository key (every vault of the repository under the same key re-encrypted with one slot for it) and the outer cipher (XChaCha20-Poly1305, AES-256-GCM); the outer encryption added (under a new repository key or the key the repository's other vaults use) or removed, which moves the vault to `.kdbx.tsmx` or `.kdbx` through the service (`vault.move`) and cuts the repository's history; for the primary, the note that other devices get its new key file, repository key or place by pairing or by hand; then what was written, the history cut, copies of the new key file and repository key to save with the recovery codes, and the new emergency sheet. `TomSecretsSession.moveOuter` and `repositoryKeysFor` carry out the move. |
| `tomSecretsShowRewrittenQuestion` | The force-push question: a vault whose branch on GitHub was rewritten without a compaction (the service refused the save and reports `rewritten`; its header and the Status screen say so) — take the file on GitHub (the refused change dropped) or merge this copy over it, sent as `history.resolve`; the vault is read again. |
| `TomSecretsHostBridge` | The tray icon and menu, the notifications for an unlock request and an approval prompt while the window is closed (DP-31; a click opens the window, where the prompt waits), the key reminder once a day while a key is due and the app runs, keeping the window out of screen capture (on by default, DP-33), start at login switched on at the first start (DP-30). |
| `TomSecretsStatusView` | The service, its stores with state, source and last fetch, the hardening achieved. |

## Ports

`TomSecretsHost` carries what the host provides: the service host
(`TomSecretsServiceHost`: attach, start, claim, the first run), the tray, the window,
notifications, the login item, the capture guard, the device's preferences,
the key-file picker, the file dialogs, the print path (`TomSecretsPrinter`), opening a web page (`openUrl`), the pairing window's addresses (`pairingAddresses`; `pairingAllowsLoopback` for tests), mDNS for pairing on the LAN (`pairingDiscovery`, `TomSecretsPairingDiscovery`: advertise an open window, browse for one), the clipboard and what the First run
wizard's last step offers. `tom_secrets_desktop`
implements them on macOS, Windows and Linux; a test uses fakes.

## Configuration

The package has no configuration of its own. What it keeps per device goes
through the host's preferences port (`TomSecretsPreferences`): the tree/list
and vault-aware/uniform switches, screen capture, start at login, the key
reminders' snoozes. The machine's settings are the service's
(`settings.get` / `settings.set`), the shared configuration is `tsm.config` in
the primary vault; the Settings screen edits both.

## Limits

- No platform code: a host without a port (a `null` tray, no printer, no
  file dialogs) gets the screens without that capability.
- Linux cannot keep a window out of screen capture; the Settings screen says
  so.
- The mobile host (phase B) does not exist yet.

## Testing

```text
flutter test
```

The tests run the screens and controllers against an in-memory stand-in for
the service holding real demo vaults (`test/support/fake_service.dart`), with
a fake GitHub for the First run's repository check. Demo data under demo keys
only.

## Dependencies

`tom_secrets_core` (the only way to KDBX, DP-29), `tom_secrets_client` (the
admin errors, the reference grammar), the Tom UI modules `tom_ui_support`
(notices, colours), `tom_host_ui` (the clipboard port), `tom_credentials_ui`
(key fields, the key-file picker, the token prompt) and `tom_sync_ui` (the
merge view, the sync indicator), `tom_basics` (the protected clipboard),
`tom_core_storage` (the token prompt's types), `tom_core_sync` (the sync
states), `pdf` (the emergency sheet), `provider`; all from pub.dev.

## Further documentation

- [The desktop app's user guide](../tom_secrets_app/doc/user_guide.md): every
  screen as a user meets it.
- [`tom_secrets_desktop`](../tom_secrets_desktop/README.md): the desktop
  implementations of the ports.
- [The repository README](../README.md): installing, building, the packages.
- The protocol between the app and the service:
  [`al-the-bear/tom_secrets_clients`](https://github.com/al-the-bear/tom_secrets_clients)
  (`protocol/protocol.md`).

## Status

Version 0.1.0 (phase A of the product). The suite covers the First run wizard
(set up here and by pairing), the shell, the vault browser and entry editor,
overlays and their resolution, conflicts, clients and approvals, keys,
rotation, token renewal, the import, pairing and the force-push question; it
runs with `flutter test` and needs no service, network or GitHub.

## Licence

BSD-3-Clause ([`LICENSE`](LICENSE)).
