# tom_secrets_app

The Tom Secrets Manager's desktop app on macOS, Linux and Windows: the
composition root over `tom_secrets_ui`'s screens and `tom_secrets_desktop`'s
host.

- One instance per user; a second launch brings the window to the front.
- Started at login with `--hidden` it starts in the tray; closing the window
  keeps it there, and it quits only from the tray menu (DP-30). Quitting
  leaves the service running (BP-14).
- The window is kept out of screen capture by default (DP-33).

## Running it

The app talks to the secrets service of the user who runs it. It finds the
service in the user's runtime directory (`TSM_RUNTIME_DIR` to name another),
starts it from `tom_secrets_service` beside the app (`TSM_SERVICE` to name
another) with `bootstrap.yaml` in the data directory (`TSM_DATA_DIR`), and
keeps the admin key in the OS keychain, where `tsm` finds it too. The service
takes admin commands only from the app beside it, `tsm` beside it, or an
executable its bootstrap names in `admin_executables`.

`TSM_LOGIN_ITEM=off` keeps a development run from registering its build as a
login item, and removes such a registration made before.

```text
flutter run -d macos     # or linux, windows
flutter build macos      # build/macos/Build/Products/Release/tom_secrets_app.app
```

macOS builds through Swift Package Manager (no CocoaPods); the app is not
sandboxed (`macos/Runner/*.entitlements` says why). A Linux build needs
`libayatana-appindicator3-dev` (the tray) and `libsecret-1-dev`. A Windows
build needs Visual Studio 2022 Build Tools with "Desktop development with
C++" and the ATL component: `flutter_secure_storage_windows` and
`flutter_local_notifications_windows` include ATL headers and C++20
coroutines, which the 2019 tools without ATL refuse.

## Licence

BSD-3-Clause (`LICENSE`); `../THIRD_PARTY.md` lists what the app bundles.
