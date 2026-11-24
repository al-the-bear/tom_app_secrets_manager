# Changelog

## 0.1.0

- The Windows 11 passkey plugin `tsm-passkey-plugin.exe`: the COM server
  Windows starts with `-PluginActivated` (`IPluginAuthenticator`:
  `MakeCredential`, `GetAssertion`, `CancelOperation`, `GetLockStatus`),
  every request's signature verified with the operation-signing key, CTAP2
  decoded and encoded by `webauthn.dll` (its functions loaded with
  `GetProcAddress`), the service asked with `passkeys`, `passkeyGet` and
  `passkeyCreate` (protocol.md 5.8) through the C client; never a key.
- The commands the app runs: `--register`, `--unregister`, `--state`,
  `--sync-credentials` (the passkeys' names Windows lists).
