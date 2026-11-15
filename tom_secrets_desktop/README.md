# tom_secrets_desktop

The desktop host of the Tom Secrets Manager's manager app on macOS, Windows
and Linux: the implementations of `tom_secrets_ui`'s ports. Each third-party
plugin sits behind a port, so it can be swapped (DP-32).

| Port | Implementation |
| --- | --- |
| Service host | `TomSecretsDesktopServiceHost`: the runtime directory of this user's service; starting it (`tomSecretsStartService`, the service executable from `TSM_SERVICE` or beside the app, `bootstrap.yaml` in the data directory); attaching with the admin key kept in the OS keychain under tsm's handle (`tsm.admin.<start>`, service `tom-secrets-manager`, through `tom_core_storage`'s `TomDesktopSecretStore`), so the app and tsm share it; claiming with the master password; a machine without `bootstrap.yaml` answers not set up, and its first run (`TomSecretsFirstRun`) writes into the data directory (`TSM_DATA_DIR`, else the platform's) and the OS keychain. |
| Tray | `TomSecretsPluginTray` over `tray_manager`: the macOS menu bar (template images), the Windows notification area (ICO), the Linux tray (StatusNotifierItem through AppIndicator); the icons in `assets/tray/` (`tool/make_tray_icons.py` draws them). |
| Window | `TomSecretsPluginWindow` over `window_manager`: closing hides the window (the app stays in the tray, DP-30), or minimises it where no tray is. |
| Notifications | `TomSecretsPluginNotifier` over `flutter_local_notifications`. |
| Start at login | `TomSecretsDesktopLoginItem`: macOS through this package's own `SMAppService` code (macOS 13+), Windows and Linux through `launch_at_startup`, with `--hidden`. |
| Screen capture | `TomSecretsPlatformCaptureGuard`, this package's own code: `NSWindow.sharingType = .none` on macOS, `SetWindowDisplayAffinity(WDA_EXCLUDEFROMCAPTURE)` on Windows (10 2004+); Linux cannot exclude a window (DP-33). |
| Clipboard | `tomSecretsDesktopClipboard()`: `tom_reusable_ui`'s `TomDesktopClipboardPort`, its macOS half (the concealed and transient pasteboard markers) in this package's code. |
| Preferences, files | `TomSecretsFilePreferences` (`app-preferences.json` in the data directory, never synced), `TomSecretsDesktopFiles` (`file_selector`: key files, attachments, the First run's vault file and the copies of its new keys). |
| Print path | `TomSecretsDesktopPrinter` over `printing`: the system print dialog for the emergency sheet (on Windows and Linux `printing` bundles PDFium, which its build downloads). |
| One instance | `TomSecretsSingleInstance`: a second launch brings the window to the front (`app.port` in the data directory). |

The platform code is in `macos/` (Swift, the channels
`tom_secrets_desktop/capture`, `/clipboard`, `/login`) and `windows/` (C++,
`/capture`).

## Testing

```text
flutter test
```

The service host's tests run the real service in-process on demo vaults; the
others check one instance, the preferences file, the capture guard per
platform and the tray assets.

`tool/demo_installation.dart <folder> [<app executable>]` writes a demo
installation (bootstrap, demo vaults) for trying the app by hand; see its
header.

## Licence

BSD-3-Clause (`LICENSE`).
