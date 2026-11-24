# tom_secrets_passkey_plugin

> Part of the Tom Secrets Manager by Peter Nicolai Alexis Kyaw, BSD-3-Clause.

The Windows 11 passkey plugin of the Tom Secrets Manager
(part-os-integration): `tsm-passkey-plugin.exe`, which lets Windows' own
passkey dialog use the passkeys of the vaults, in every browser and app.

## Overview

Windows 11 (24H2 and later) lets a password manager add itself as a
passkey provider. Windows shows its passkey dialog, the user picks a
passkey or confirms a new one there, and Windows hands the request to the
provider's plugin: an out-of-process COM server named in the provider's
MSIX package.

This plugin is that COM server. It holds no key:

- it verifies that each request is Windows' own (its signature with the
  plugin's operation-signing key);
- it decodes the CTAP2 request with `webauthn.dll`;
- it asks the secrets service with the passkey requests of protocol.md 5.8
  (`passkeys`, `passkeyGet`, `passkeyCreate`), as the browser host does;
- it encodes the service's answer for Windows.

The service lists the passkeys of the personal and shared vaults (never a
system vault's), signs with them, and makes a new one once the user
confirms it in the manager app. It admits the plugin by its measured
executable: `tsm-passkey-plugin.exe` beside the service's own.

## Installation

The plugin ships in the manager app's MSIX package, in `tsm\bin` beside
the service. Windows registers a plugin only from a package: an unpackaged
copy is refused (`0x80073D54`).

1. Install the package. The package is signed with a self-signed
   certificate, so each machine must trust it first. An administrator runs
   `tom_secrets_build\windows\install_signing_certificate.ps1` with the
   certificate once.
2. In the app: Settings › Integrations › Windows passkeys, then Add to
   Windows.
3. In Windows: Settings › Accounts › Passkeys › Advanced options, turn on
   Tom Secrets Manager.

## Usage

Windows starts the plugin itself. The app runs it with one command:

| Command | What it does |
| --- | --- |
| `--register` | Adds the plugin to Windows (`WebAuthNPluginAddAuthenticator`): its name, class id, logos and `authenticatorGetInfo`. |
| `--unregister` | Removes it, and the passkey names Windows keeps. |
| `--state` | Prints `enabled`, `disabled` (added, not turned on) or `not-registered`. |
| `--sync-credentials` | Replaces the passkeys Windows lists with the lines on standard input. |

Each command prints one line and exits 0, or prints the failure on
standard error and exits 1.

Each `--sync-credentials` line names one passkey: six tab-separated
base64url fields (credential id, relying party, its name, user handle,
user name, display name; the texts as UTF-8). The app writes the list
after every unlock and change. It never carries a key.

## How a request is answered

- **A sign-in** (`GetAssertion`): Windows names the passkey the user
  picked. The plugin asks `passkeys` for the relying party with that
  credential id (waiting for an unlock or an approval), then `passkeyGet`
  over the client data hash.
- **A new passkey** (`MakeCredential`): `passkeyCreate` with the user, the
  algorithms the site offers (ES256 when it names none) and the credentials
  it excludes. The app asks "Save a passkey for …?", and the service keeps
  the passkey in a vault before it answers.
- **The lock** (`GetLockStatus`): unlocked when the service answers a
  `passkeys` probe without waiting.
- **Refusals** answer Windows: a passkey the site holds already
  `NTE_EXISTS`; a no in the app, or none in the vaults,
  `NTE_USER_CANCELLED`; a locked or stopped service `NTE_DEVICE_NOT_READY`;
  an unsigned request `NTE_BAD_SIGNATURE`.

The page the service is told is `https://<rpId>/`: Windows checked the
caller's origin against the relying party before it signed the request.

## User verification

The service's approval prompt is the user verification, with no Windows
Hello prompt of the plugin's own:

- A sign-in asks in the app the first time only. "Always" writes a grant
  for the plugin, and later sign-ins need no prompt of the app.
- A new passkey is always confirmed in the app.
- Windows' own passkey dialog always shows: it is where the user picks the
  passkey.

## Logging

The plugin writes what failed (never a value) to
`%LOCALAPPDATA%\TomSecretsManager\passkey-plugin.log`.

## Building

A CMake project in C++17 over the C client (`tsm::tsm`, fetched from its
release tag `clients/c/v0.2.0`):

```text
cmake -S . -B build -DTSM_WERROR=ON
cmake --build build --config Release
ctest --test-dir build -C Release --output-on-failure
```

A local checkout of `tom_secrets_clients` replaces the tag:
`-DFETCHCONTENT_SOURCE_DIR_TSM_C=<checkout>`. The CI's `:analyze` and
`:test` build and test it everywhere; the executable is built on Windows
only (with the Windows SDK 10.0.26100, whose `webauthn.h`,
`webauthnplugin.h` and `pluginauthenticator.h` it includes).
`tom_secrets_build`'s `ci.ps1 :release` builds it into the MSIX package.

The tests:

- `tsm_plugin_tests` (every platform): the core against a fake service.
  It checks what a request asks the service and what the answers become.
- `tsm_plugin_windows_tests` (Windows): the COM authenticator against
  recorded CTAP2 requests, decoded and encoded by `webauthn.dll`. It also
  checks the lock status and the refusal of a request Windows did not sign.

## Limits

- Windows 11 24H2 (build 26100) or later; earlier Windows lack the plugin
  functions, and the commands say so.
- The package is self-signed for now: each machine trusts its certificate
  in Trusted People.
- The plugin serves the passkeys of the vaults the service has open on
  this machine; a locked service answers locked, and Windows asks to try
  again.

## Licence

BSD-3-Clause, see [LICENSE](LICENSE).
