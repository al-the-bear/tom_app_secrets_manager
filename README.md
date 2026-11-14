# Tom Secrets Manager — applications

The applications of the Tom Secrets Manager: the desktop app (a password
manager and the editor for system secrets), and later the mobile app, the
browser extension and the relay server, with the manual CI and the shared test
fixtures. Laid out as `app_webwork` is: a flat set of packages at the top.

In the workspace this repository is the submodule `app_secrets_manager`
(repository id `TSMA`, GitHub `al-the-bear/tom_app_secrets_manager`, private).

## Packages

| Package | Phase | What it holds |
| --- | --- | --- |
| [`tom_secrets_ui`](tom_secrets_ui/) | A | the shell, screens and state both apps use: unlock, the vault browser, the entry editor, over ports the host implements |
| [`tom_secrets_desktop`](tom_secrets_desktop/) | A | the desktop host: starting and attaching to the service, tray and menu bar, window, notifications, start at login, screen-capture exclusion, the protected clipboard |
| [`tom_secrets_app`](tom_secrets_app/) | A | the desktop composition root (macOS, Linux, Windows), shipping the service binary beside itself |
| [`tom_secrets_build`](tom_secrets_build/) | A | the manual CI: analyze, test and the licence-boundary check over every package of the three repositories, started by a person (`ci.sh`, `ci.ps1`, `ci.cmd`) |
| [`tom_secrets_testkit`](tom_secrets_testkit/) | A | test fixtures more than one package needs (the scratch folder so far); a dev dependency only |
| `tom_secrets_mobile` | B | the mobile composition root (iOS/iPadOS, Android) |
| `tom_secrets_browser` | B | the WebExtension and its native-messaging host |
| `tom_secrets_relay` | C | the optional relay server |

The phase-A packages exist; the others are created by the quest's todos of
their phase.

## Checking it

```bash
tom_secrets_build/ci.sh :all
```

analyzes and tests every package of the three repositories and runs the
licence-boundary check; see [`tom_secrets_build/README.md`](tom_secrets_build/README.md).

## Licence

Every package here is BSD-3 (`LICENSE`); `THIRD_PARTY.md` lists the licences
of what the apps bundle. The apps reach KDBX only through
`tom_secrets_core`. The binaries go into the public `tom_binaries`, each with
its `LICENSE` row.

## Design

The design is the idea document of the tom_core quest,
`_ai/quests/tom_core/ideas/tom_secrets_manager/tom_secrets_manager.md`
(sections `part-repositories`, `part-app`); the work is tracked in the
`tom_secrets_manager` quest.
