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
| `TomSecretsSession` | The vaults open in the app's memory: the copy the service holds of each store (`vaultKeys`, then `vaultFile`, protocol 6.4), opened with its keys through `tom_secrets_core`; the search index; the selection; the tree/list switch (kept per device); edits saved through the service (`save` against the revision read), a change from elsewhere read again; everything dropped on `locked`. |
| `TomSecretsFirstRunWizard` | Opened when the machine is not set up (no service runs and the data directory holds no `bootstrap.yaml`). Step 1: create a primary vault or open one, on this computer or in a GitHub repository (the token entered through `showTomTokenDialog` and the repository checked through `withTomTokenFlow`, its expiry as GitHub reports it or entered); the master password (`TomKeyFields` with the key file when opening). Step 2: the key file and the outer encryption (XChaCha20-Poly1305 or AES-256-GCM), each optional, with a copy saved where the user chooses. Step 3: the machine's name, default environment, the files it serves, the lock mode, where the device settings' key is kept. Then `tom_secrets_core`'s `TomSecretsFirstRun` writes the setup, the service is started and unlocked with the master password, and step 4 offers the import and the pairing the host provides (`TomSecretsHost.firstRunActions`). |
| Unlock, claim, connection screens | The master password and key file (`TomKeyFields`); a store with a password of its own opened on the vault browser (BP-8); the warning before a claim sends the master password (DP-16); starting a service that is not running. |
| `TomSecretsMainShell` | The rail (Vaults, Status), the top bar (search over every vault, tree/list, the sync status of the GitHub vaults, the approvals and key-expiry badges, lock) and the keyboard shortcuts (Cmd/Ctrl+F search, +L lock, +N new entry, +1 tree, +2 list, +S save in the editor). |
| `TomSecretsVaultBrowser` | The tree view (group tree, entry list, details) and the list view (vault, type and tag filters); overlay groups (`@host:…`) shown as the entry's overlays, not folders; multi-select move, tag, delete to the recycle bin; groups created, renamed and moved; an offline vault marked with its reason and age. |
| `TomSecretsEntryEditor` | Login, API token and secure note: title, user name, the password with the generator, URLs, TOTP with its countdown, notes, custom fields (protected or not), tags, expiry, attachments, "How clients name it" (the path reference and the `tsm.key`, checked for uniqueness in the vault), the history with Restore. Protected values are masked, revealed one at a time for 30 seconds and copied through the protected clipboard (cleared after 30 seconds). A vault served from its offline copy opens read-only. |
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
