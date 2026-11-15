# Tom Secrets Manager — applications

The applications of the Tom Secrets Manager: the desktop app (a password
manager and the editor for system secrets), and later the mobile app, the
browser extension and the relay server, with the manual CI and the shared test
fixtures. A flat set of packages at the top.

GitHub: `al-the-bear/tom_app_secrets_manager`. The product's other two
repositories are `al-the-bear/tom_secrets_manager` (the core and the secrets
service) and `al-the-bear/tom_secrets_clients` (the protocol, the client
libraries and `tsm`).

## Installing

Each release is a release of the `al-the-bear/tom_binaries` repository on
GitHub (tag `tom_secrets_manager-v<version>`), one archive per platform:

| Platform | Archive | Install |
| --- | --- | --- |
| macOS (Apple silicon) | `tom_secrets_manager-<version>-macos-arm64.zip` | unzip, move `Tom Secrets Manager.app` to `/Applications`; the app is ad-hoc signed, so open it the first time with Control-click › Open |
| Windows (x64) | `tom_secrets_manager-<version>-windows-x64.zip` | unzip into a folder of your choice and start `tom_secrets_app.exe` |
| Linux (x64) | `tom_secrets_manager-<version>-linux-x64.tar.gz` | unpack into a folder of your choice and start `tom_secrets_app` |

The app carries everything it needs: the secrets service and the command
line `tsm` are inside it, in its `tsm/bin` folder (on macOS
`Tom Secrets Manager.app/Contents/Resources/tsm/bin`). To use `tsm` from a
shell, link it onto your `PATH`, e.g. on macOS:

```text
ln -s "/Applications/Tom Secrets Manager.app/Contents/Resources/tsm/bin/tsm" /usr/local/bin/tsm
```

A server without a desktop takes `tom_secrets_tsm-<version>-<platform>` of
the same release: `tsm` and the service alone (`bin/`, `lib/`), started and
unlocked with `tsm start` and `tsm unlock`.

## First run

On a machine that is not set up yet, the app opens its First run wizard:

1. create a primary vault or open an existing one, on this computer or in a
   private GitHub repository (with a fine-grained personal access token for
   that repository, kept in the OS keychain);
2. optionally protect it with a key file and an outer encryption (each adds a
   key you must keep a copy of: the wizard offers to save one);
3. name the machine and choose its default environment, the vaults it serves
   and when the service locks.

It then starts the service and unlocks it. The setup is kept in the app's
data directory (`~/Library/Application Support/TomSecretsManager`,
`%LOCALAPPDATA%\TomSecretsManager`, `~/.local/share/tom-secrets-manager`;
`TSM_DATA_DIR` names another).

## Building from source

Clone the three repositories side by side under their GitHub names:

```text
git clone https://github.com/al-the-bear/tom_app_secrets_manager.git
git clone https://github.com/al-the-bear/tom_secrets_manager.git
git clone https://github.com/al-the-bear/tom_secrets_clients.git
```

With Flutter 3.38 or later on the `PATH`:

```text
tom_app_secrets_manager/tom_secrets_build/ci.sh :release
```

builds the app for this platform with `tsm` and the service inside it, and
writes the release archives to `tom_secrets_build/release/<version>/`. Where
the other two repositories are elsewhere,
`tom_secrets_build/repositories.yaml` names them (see
[`tom_secrets_build/README.md`](tom_secrets_build/README.md)).

The packages take their dependencies from pub.dev (the core, the service,
the client and `tsm` are there: `tom_secrets_core`, `tom_secrets_service`,
`tom_secrets_client`, `tom_secrets_tsm`), or by path inside one repository.
One exception is left: the apps take `tom_reusable_ui` by path from the
`tom_app_webwork` repository, which is not published yet, so building the
apps needs that checkout beside this one until it is; `ci.sh :standalone`
lists it.

## Packages

| Package | Phase | What it holds |
| --- | --- | --- |
| [`tom_secrets_ui`](tom_secrets_ui/) | A | the shell, screens and state both apps use: the First run wizard, unlock, the vault browser, the entry editor, over ports the host implements |
| [`tom_secrets_desktop`](tom_secrets_desktop/) | A | the desktop host: starting and attaching to the service, tray and menu bar, window, notifications, start at login, screen-capture exclusion, the protected clipboard |
| [`tom_secrets_app`](tom_secrets_app/) | A | the desktop composition root (macOS, Linux, Windows), shipping `tsm` and the service inside its distribution |
| [`tom_secrets_build`](tom_secrets_build/) | A | the manual CI (analyze, test, the licence-boundary and standalone checks over every package of the three repositories) and the release build, started by a person (`ci.sh`, `ci.ps1`, `ci.cmd`) |
| [`tom_secrets_testkit`](tom_secrets_testkit/) | A | test fixtures more than one package needs (the scratch folder so far); a dev dependency only |
| `tom_secrets_mobile` | B | the mobile composition root (iOS/iPadOS, Android) |
| `tom_secrets_browser` | B | the WebExtension and its native-messaging host |
| `tom_secrets_relay` | C | the optional relay server |

## Checking it

```text
tom_secrets_build/ci.sh :all
```

analyzes and tests every package of the three repositories and runs the
licence-boundary and standalone checks; see
[`tom_secrets_build/README.md`](tom_secrets_build/README.md).

## Licence

Every package here is BSD-3 (`LICENSE`); `THIRD_PARTY.md` lists the licences
of what the apps bundle. The apps reach KDBX only through
`tom_secrets_core`.

## Design

The design decisions the code and documents cite (`DP-`, `BP-`, `TD-` and
`IDEA-` ids, the `part-…` sections) are recorded in the product's design
document, which is not published with the source. The published contract
between the service and its clients is the protocol document of
`al-the-bear/tom_secrets_clients` (`protocol/protocol.md`).
