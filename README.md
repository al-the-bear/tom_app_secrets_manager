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
| `tom_secrets_ui` | A | the shell, screens and widgets both apps use |
| `tom_secrets_desktop` | A | the desktop host capabilities: the service, tray and menu bar, the platform secret store, notifications |
| `tom_secrets_app` | A | the desktop composition root (macOS, Linux, Windows), shipping the service binary beside itself |
| `tom_secrets_build` | A | the manual CI: analyze, test, audit and build every package, started by a person |
| `tom_secrets_testkit` | A | test fixtures more than one package needs; a dev dependency only |
| `tom_secrets_mobile` | B | the mobile composition root (iOS/iPadOS, Android) |
| `tom_secrets_browser` | B | the WebExtension and its native-messaging host |
| `tom_secrets_relay` | C | the optional relay server |

The packages are created by the quest's todos of their phase; until then the
repository holds only its frame.

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
