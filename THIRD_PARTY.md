# Third-party software

The Tom Secrets Manager applications are licensed under the BSD 3-Clause
License; the text is in [`LICENSE`](LICENSE). That licence covers the
applications' own code. This file lists the work of others the applications
bundle and the terms each sets: the direct dependencies of the shipped
composition roots. Development-only dependencies are not listed; a Flutter
build collects the licence text of every package it links, transitive ones
included, into the application it produces.

A package that adds a shipped dependency adds its row here.

| Dependency | Licence | Used by |
| --- | --- | --- |
| [provider](https://pub.dev/packages/provider) | MIT | `tom_secrets_ui`: the controllers in the widget tree |
| [tray_manager](https://pub.dev/packages/tray_manager) | MIT | `tom_secrets_desktop`: the tray and menu bar |
| [window_manager](https://pub.dev/packages/window_manager) | MIT | `tom_secrets_desktop`: the window (closing hides it) |
| [flutter_local_notifications](https://pub.dev/packages/flutter_local_notifications) | BSD-3-Clause | `tom_secrets_desktop`: system notifications |
| [dbus](https://pub.dev/packages/dbus) | MPL-2.0 | `tom_secrets_desktop`, `tom_secrets_app` on Linux, through `flutter_local_notifications_linux`; unmodified; source: https://github.com/canonical/dbus.dart. The one named exception of the licence boundary (`secretsLicenceExceptions`) |
| [launch_at_startup](https://pub.dev/packages/launch_at_startup) | MIT | `tom_secrets_desktop`: start at login on Windows and Linux |
| [file_selector](https://pub.dev/packages/file_selector) | BSD-3-Clause | `tom_secrets_desktop`: key files and attachments |

The app's distribution also carries the command line `tsm` and the secrets
service (its `tsm` folder), built from the product's other two repositories
(BSD-3, the same `LICENSE`); the service links `tom_pqc` (BSD-3), whose
native library vendors mlkem-native and mldsa-native (MIT); a release
carries their licence texts and `tom_pqc`'s in its `licenses/` folder.
