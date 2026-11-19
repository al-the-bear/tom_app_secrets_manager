# tom_secrets_browser

> Part of the Tom Secrets Manager by Peter Nicolai Alexis Kyaw, BSD-3-Clause.

The browser integration of the Tom Secrets Manager (part-browser). This
package is the native-messaging host `tsm-browser-host`: the program the
browsers start for the product's extension, which talks to the secrets
service over the client protocol. The WebExtension itself joins this package
next (Chromium and Firefox builds from one TypeScript source).

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
- `match {url, frameUrl?}`: `candidates` `[{entryId, title, userName,
  matchedUrl, hasTotp}]`, never a value.
- `fill {entryId, url, frameUrl?, totp?}`: the page is matched again and the
  entry must be one of its candidates (else `denied`, reason `not_matched`,
  before any value is read); then `userName`, `password` and, when asked and
  the entry has one, the current `totp`, read in one `getMany`.
- `propose {url, title?, userName, password}`: passed to the attached app
  (the service's `propose`): `accepted`, `known`.
- `openApp {entryId?}`: starts the desktop app of the distribution the host
  is in with `--show-entry <entryId>` (on macOS `open -n -a` on the bundle):
  a running app comes to the front and shows the entry (`unavailable`,
  reason `no_app`, when the app is not there).

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
with no service running. `match` and `propose` against the real service are
the service's own tests (`tom_secrets_service`'s `lookup_test.dart`).

## Limits

- The extension ids of the Chrome Web Store and Edge Add-ons are added when
  the extension is published there; until then the development build's id
  (fixed by its key) is the only Chromium id served.
- Safari has no stdio host: its extension is answered by a Swift handler in
  the macOS app (phase C).
