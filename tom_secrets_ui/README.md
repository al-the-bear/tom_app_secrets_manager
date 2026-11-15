# tom_secrets_ui

The screens and state of the Tom Secrets Manager's manager app, shared by the
desktop app and (phase B) the mobile app. The host implements the ports
(`TomSecretsHost`) and runs `TomSecretsApp`; this package decides no
platform.

## What it holds

| Part | What it does |
| --- | --- |
| `TomSecretsApp` | The root: the controllers provided to the widget tree, the screen the connection's phase calls for, the compact theme. |
| `TomSecretsServiceConnection` | The admin connection: attaching, starting and claiming the service, unlock and lock, `status`, the event stream (`locked`, `unlocked`, `store_state`, `unlock_needed`, `approval_needed`, `key_expiry`), a dropped connection. |
| `TomSecretsSession` | The vaults open in the app's memory: the copy the service holds of each store (`vaultKeys`, then `vaultFile`, protocol 6.4), opened with its keys through `tom_secrets_core`; the search index; the selection; the tree/list and vault-aware/uniform switches (kept per device); the resolution model (`resolution`); overlays created and edited; conflicts settled field by field; the vaults the primary lists that this machine does not serve (`unserved`), opened for editing only through the service (`openUnserved`: `vaultKeys` and `vaultFile` naming the vault) and saved like every other; edits saved through the service (`save` against the revision read), a change from elsewhere read again; everything dropped on `locked`. |
| `TomSecretsFirstRunWizard` | Opened when the machine is not set up (no service runs and the data directory holds no `bootstrap.yaml`). Step 1: create a primary vault or open one, on this computer or in a GitHub repository (the token entered through `showTomTokenDialog` and the repository checked through `withTomTokenFlow`, its expiry as GitHub reports it or entered); the master password (`TomKeyFields` with the key file when opening). Step 2: the key file and the outer encryption (XChaCha20-Poly1305 or AES-256-GCM), each optional, with a copy saved where the user chooses. Step 3: the machine's name, default environment, the files it serves, the lock mode, where the device settings' key is kept. Then `tom_secrets_core`'s `TomSecretsFirstRun` writes the setup, the service is started and unlocked with the master password, and step 4 offers the import and the pairing the host provides (`TomSecretsHost.firstRunActions`). |
| Unlock, claim, connection screens | The master password and key file (`TomKeyFields`); a store with a password of its own opened on the vault browser (BP-8); the warning before a claim sends the master password (DP-16); starting a service that is not running. |
| `TomSecretsMainShell` | The rail (Vaults, Environments, Conflicts with the count of conflicted entries, Status), the top bar (search over every vault, tree/list, vault-aware/uniform, the sync status of the GitHub vaults, the approvals and key-expiry badges, lock) and the keyboard shortcuts (Cmd/Ctrl+F search, +L lock, +N new entry, +1 tree, +2 list, +S save in the editor). |
| `TomSecretsVaultBrowser` | The tree view (group tree, entry list, details) and the list view (vault, type and tag filters); overlay groups (`@host:…`) shown as the entry's overlays, not folders; multi-select move, tag, delete to the recycle bin; groups created, renamed and moved; an offline vault marked with its reason and age. In the vault-aware view a system vault's entry shows its key, the dimensions it is bound in and which clients read it and when (the grants of every host), a personal or shared vault's entry its login, URL and TOTP; the uniform view shows each of them the entry has (`tomSecretsEntryDetails`). |
| `TomSecretsEntryEditor` | Login, API token and secure note: title, user name, the password with the generator, URLs, TOTP with its countdown, notes, custom fields (protected or not), tags, expiry, attachments, "How clients name it" (the path reference and the `tsm.key`, checked for uniqueness in the vault), "Overlays…" opening the overlay editor, the history with Restore. Protected values are masked, revealed one at a time for 30 seconds and copied through the protected clipboard (cleared after 30 seconds). A vault served from its offline copy opens read-only. |
| `TomSecretsResolutionModel` | The open vaults as the service's resolver sees them: the primary's configuration (the dimensions in priority order), every vault as a store; the dimension values a matrix has rows for (hosts from the grants, the devices and the bindings; every platform; the configured environments); what a request gets, step by step (the request's values, every candidate kept with its rank vector or dropped with the binding that drops it, the answer: the shared entry, an overlay, another file, none, ambiguous); the clients granted an entry. |
| `TomSecretsOverlayEditor` | One entry and its overlays as a matrix: the shared entry, then per dimension one row per value with the value it gets (masked when protected) and where it comes from; a cell edited in place; a click on a row without an overlay of its own creates one (`@<dimension>:<value>/<groups>/<title>`, a copy of the shared entry) and edits it; an overlay removed with its menu; a row of a dimension the file is bound to edits the entry in that value's file. "Which value does … get?" takes qualifiers (`[env:prod,host:bomber]`) and shows the resolution step by step; ambiguities in red. |
| `TomSecretsEnvironmentsView` | The keys (`tsm.key`) across the environments' files side by side, one column per served file and per vault not served that is open for editing; the vaults the primary lists that this machine does not serve offered to open (the service reads each from its location with its listed keys and writes its saves there, protocol 6.4), the configured files the primary lists no keys for named; a cell edited in place and saved, an empty cell creating the entry. |
| `TomSecretsConflictsView` | The entries with an unsettled conflict (`tsm.conflict`) and `TomMergeView` over their fields: the value the merge kept and the one it replaced (from the entry's history), masked when protected; keep one side or edit the result; confirming writes it, takes the field off the record (the last one clears it) and saves. |
| `TomSecretsHostBridge` | The tray icon and menu, the notification for an unlock request while the window is closed, keeping the window out of screen capture (on by default, DP-33), start at login switched on at the first start (DP-30). |
| `TomSecretsStatusView` | The service, its stores with state, source and last fetch, the hardening achieved. |

## Ports

`TomSecretsHost` carries what the host provides: the service host
(`TomSecretsServiceHost`: attach, start, claim, the first run), the tray, the window,
notifications, the login item, the capture guard, the device's preferences,
the key-file picker, the file dialogs, the clipboard and what the First run
wizard's last step offers. `tom_secrets_desktop`
implements them on macOS, Windows and Linux; a test uses fakes.

## Testing

```text
flutter test
```

The tests run the screens and controllers against an in-memory stand-in for
the service holding real demo vaults (`test/support/fake_service.dart`).

## Dependencies

`tom_secrets_core` (the only way to KDBX, DP-29), `tom_secrets_client` (the
admin errors, the reference grammar), `tom_reusable_ui` (key fields, notices,
sync indicator, masked editing surface, colours), `tom_basics` (the protected
clipboard), `tom_core_sync`, `provider`. `pubspec_overrides.yaml` unifies the
source of three packages that `tom_secrets_core` takes from pub.dev and
`tom_reusable_ui` by path, at the same versions (see the file).

## Licence

BSD-3-Clause (`LICENSE`).
