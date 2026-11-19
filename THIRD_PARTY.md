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
| [bonsoir](https://pub.dev/packages/bonsoir) | MIT | `tom_secrets_ui` (both apps): mDNS for pairing on the LAN (the open pairing window advertised as `_tsm-pair._tcp`, found by the code's number); with its platform packages `bonsoir_darwin`, `bonsoir_windows`, `bonsoir_linux` (Avahi over D-Bus), `bonsoir_android` and `bonsoir_platform_interface`, all MIT |
| [dbus](https://pub.dev/packages/dbus) | MPL-2.0 | `tom_secrets_ui`, `tom_secrets_desktop`, `tom_secrets_app` on Linux, through `flutter_local_notifications_linux` and `bonsoir_linux`; unmodified; source: <https://github.com/canonical/dbus.dart>. In `tom_secrets_mobile`'s closure through `bonsoir_linux` too, but never built into the iOS or Android app. The one named exception of the licence boundary (`secretsLicenceExceptions`) |
| [win32_registry](https://pub.dev/packages/win32_registry) | BSD-3-Clause | `tom_secrets_desktop`: start at login on Windows (the Run key) |
| [tom_biometric_storage](https://pub.dev/packages/tom_biometric_storage) | MIT | `tom_secrets_desktop`, `tom_secrets_mobile`: the OS unlock's item behind Touch ID, Face ID, Windows Hello or the fingerprint, and the phone's keychain (the fork of `biometric_storage`, github.com/al-the-bear/tom_biometric_storage) |
| [path_provider](https://pub.dev/packages/path_provider) | BSD-3-Clause | `tom_secrets_mobile`: the app's support directory (its preferences file) |
| [http](https://pub.dev/packages/http) | BSD-3-Clause | `tom_secrets_mobile`: GitHub's REST API |
| [mobile_scanner](https://pub.dev/packages/mobile_scanner) | BSD-3-Clause | `tom_secrets_mobile`: the camera's QR reader (the desktop's pairing code, TOTP secrets); on iOS over Apple's AVFoundation; on Android over Google's ML Kit barcode scanning model (`com.google.mlkit:barcode-scanning`), bundled into the APK: closed source under the [ML Kit terms](https://developers.google.com/ml-kit/terms), not copyleft |
| [androidx.biometric](https://developer.android.com/jetpack/androidx/releases/biometric) | Apache-2.0 | `tom_secrets_mobile` (Android, Gradle): BiometricPrompt before the Autofill service answers from the running app |
| [androidx.autofill](https://developer.android.com/jetpack/androidx/releases/autofill) | Apache-2.0 | `tom_secrets_mobile` (Android, Gradle): the Autofill service's inline suggestion in the keyboard |
| [file_selector](https://pub.dev/packages/file_selector) | BSD-3-Clause | `tom_secrets_desktop`: key files and attachments |
| [cryptography](https://pub.dev/packages/cryptography) | Apache-2.0 | `tom_secrets_ui`: AES-256-GCM of the macOS AutoFill snapshot (also in the closure through `tom_secrets_core`) |
| [pdf](https://pub.dev/packages/pdf) | Apache-2.0 | `tom_secrets_ui`: the emergency sheet as a PDF (its QR codes through `barcode`, Apache-2.0, and `qr`, BSD-3-Clause) |
| [qr](https://pub.dev/packages/qr) | BSD-3-Clause | `tom_secrets_ui`: the pairing window's QR code on the desktop's Pairing screen |
| [url_launcher](https://pub.dev/packages/url_launcher) | BSD-3-Clause | `tom_secrets_desktop`: GitHub's token pages in the system browser |
| [printing](https://pub.dev/packages/printing) | Apache-2.0 | `tom_secrets_desktop`: the system print dialog for the emergency sheet; on Windows and Linux its build downloads the PDFium library (BSD-3-Clause and Apache-2.0, [pdfium-binaries](https://github.com/bblanchon/pdfium-binaries), version 5200), which the application then bundles |

The app's distribution also carries the command line `tsm` and the secrets
service (its `tsm` folder), built from the product's other two repositories
(BSD-3, the same `LICENSE`); the service links `tom_pqc` (BSD-3), whose
native library vendors mlkem-native and mldsa-native (MIT); a release
carries their licence texts and `tom_pqc`'s in its `licenses/` folder.
