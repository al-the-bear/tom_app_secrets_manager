# tom_secrets_browser

> Part of the Tom Secrets Manager by Peter Nicolai Alexis Kyaw, BSD-3-Clause.

The browser integration of the Tom Secrets Manager (part-browser). This
package holds two parts:

- the native-messaging host `tsm-browser-host`, the program the browsers
  start for the product's extension, which talks to the secrets service over
  the client protocol (this README);
- the WebExtension in [`extension/`](extension/), Manifest V3 builds for
  Chromium browsers and Firefox from one TypeScript source: the page's
  logins, the list at the field, the fill
  ([its README](extension/README.md)).

## Overview

A browser starts the host when the extension opens a port
(`connectNative`) and stops it when the port closes; one host runs per
browser profile that uses it. The host:

- speaks native messaging on standard input and output: each message a
  32-bit length in the machine's byte order and that many bytes of UTF-8
  JSON; a message to the browser is at most 1 MB, a request at most 64 KiB;
- serves only the product's own extensions: Chromium browsers pass the
  calling extension's origin (`chrome-extension://<id>/`) as the first
  argument, Firefox the manifest's path and the extension's id; the ids are
  compiled in (`tom_secrets_client`'s `tomSecretsChromiumExtensionIds`,
  `tomSecretsFirefoxExtensionId`); any other caller gets one `denied`
  (reason `origin`) and the host exits;
- connects to the service as a client named "Tom Secrets Manager browser
  extension in `<browser>` (`<origin>`)". The name is shown in the approval
  prompt and never trusted: the service recognises the host by its measured
  executable, `tsm-browser-host` beside the service (protocol.md 5.5), and
  answers `match` and `propose` only for it.

## The requests

Each request is a JSON object with an `id` and an `op`; the answer carries
the same `id`, and a refusal is `error {kind, message, reason?}` with the
service's error kind (`not_running` when no service answers).

- `status`: `state` `running`, `locked` or `not_running` (a `match` of the
  reserved name `tom-secrets.invalid` without waiting tells locked).
- `match {url, frameUrl?, wait?}`: `candidates` `[{entryId, title,
  userName, matchedUrl, hasTotp}]`, never a value. A locked service is
  waited for (the extension's "Unlock in Tom Secrets Manager"); with `wait:
  false` the answer is `locked` at once. When no grant covers a login of
  the page, the service asks the user in the app first (the browser prompt,
  protocol.md 5.5), so the answer may take until the user answered.
- `fill {entryId, url, frameUrl?, totp?}`: the page is matched again and the
  entry must be one of its candidates (else `denied`, reason `not_matched`,
  before any value is read); then `userName`, `password` and, when asked and
  the entry has one, the current `totp`, read in one `getMany`.
- `check {url, frameUrl?, userName?, password}`: whether a login the
  extension saw submitted is worth proposing: `state` `new` (no login of the
  page with that user name), `changed` (with `entryId` and `userName`: its
  password differs), `known` (a login holds this password) or `unknown`
  (locked, no value granted, or a change form without a user name on a page
  with several logins). The stored password is read and compared here, and
  never answered; the `match` does not wait for an unlock.
- `propose {url, title?, userName, password}`: passed to the attached app
  (the service's `propose`): `accepted`, `known`.
- `openApp {entryId?}`: starts the desktop app of the distribution the host
  is in with `--show-entry <entryId>` (on macOS `open -n -a` on the bundle):
  a running app comes to the front and shows the entry (`unavailable`,
  reason `no_app`, when the app is not there).
- **[C]** The passkeys (the service's protocol.md 5.8, DP-120). The host
  passes these on, and the service never answers a key:
  - `passkeys {url, rpId, allowCredentials?}`: the page's passkeys by name
    and credential id (`candidates`).
  - `passkeyGet {url, rpId, entryId, clientDataHash}`: the service signs
    for the passkey picked (`credentialId`, `authenticatorData`,
    `signature`, `userHandle`).
  - `passkeyCreate {url, rpId, userId, userName, displayName?, algorithms,
    excludeCredentials?}`: a new passkey once the user confirms it in the
    app (`credentialId`, `authenticatorData`, `attestationObject`,
    `publicKey`, `publicKeyAlgorithm`).

## Installing

The host ships in the app's distribution, in its `tsm/bin` folder beside the
service (`tom_secrets_build`'s `ci.sh :release` builds it with `dart compile
exe`). The browsers find it by their native-messaging manifest
`net.tom.secrets.json`, which the desktop app writes per user under
Settings › Integrations › Browsers (`tom_secrets_client`'s
`TomSecretsBrowserHosts`: Chrome, Chromium, Edge, Brave and Firefox on
macOS, Linux and Windows, the registry value on Windows) and checks at every
start.

```text
dart compile exe bin/tsm_browser_host.dart -o tsm-browser-host
```

## Testing

```text
testkit :test
```

The tests check the framing, the caller check, every request against a fake
service (a fill of an entry another site has refused before any value is
read), the app launcher, and the compiled run over standard input and output
with no service running, and that the extension's source names the host
and the extension ids the host serves (`extension_ids_test.dart`). `match`
and `propose` against the real service are the service's own tests
(`tom_secrets_service`'s `lookup_test.dart`). The extension's own tests are
`npm test` in `extension/`.

## Limits

- The extension ids of the Chrome Web Store and Edge Add-ons are added when
  the extension is published there; until then the development build's id
  (fixed by its key) is the only Chromium id served.
- Safari has no stdio host: its extension is answered by a Swift handler in
  the macOS app (phase C).
