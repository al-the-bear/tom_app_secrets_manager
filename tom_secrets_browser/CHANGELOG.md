# Changelog

## 0.1.0

- Safari (part-browser): the extension's Safari build (`dist/safari`,
  Safari 17), carried by the macOS app's Safari Web Extension; its
  background reaches the host through the app's Swift handler
  (`browser.runtime.sendNativeMessage`, one host process per session).
  The host serves the Safari extension's origin
  (`safari-web-extension://com.althebear.tomSecretsApp.safari/`).

- Passkeys (DP-120, protocol.md 5.8): the host's `passkeys`, `passkeyGet`
  and `passkeyCreate` over the service's; the extension takes over a page's
  WebAuthn calls in the page's world (`webauthn.js`, `world: "MAIN"`), lists
  the page's passkeys in its own list, makes the client data with the
  frame's origin from the browser and has the service sign; a new passkey
  is confirmed in the app; the browser's own WebAuthn answers whatever Tom
  Secrets Manager does not. Chrome 111 and Firefox 128 at least.
- The browser extension (`extension/`, part-browser): Manifest V3 for
  Chromium browsers and Firefox from one TypeScript source; the login
  fields found in every frame (open shadow roots too); the list of the
  page's logins in a closed shadow root at the field, opened by the
  shortcut, the context menu or the popup; the fill into the list's own
  frame only, with the events frameworks listen to; a form in a frame of
  another site offered on its own; locked, not running and no host each
  saying what to do. No runtime dependency.
- `match` takes the extension's `wait` (`false`: `locked` at once).
- The browser is approved at its first lookup (the service's browser
  prompt): the list says it is asking meanwhile, and its empty text points
  to the approval.
- Proposals (DP-43): a submitted login the vaults do not hold, or a changed
  password, brings the bar "Save in Tom Secrets Manager?" (Save, Not now,
  Never for this site; also on the page the form led to); the host's new
  `check` tells new, changed and known without answering a value. The
  in-field icons, a suggested password in new-password fields, the
  extension's icons, and the store packages in `dist/packages/`.

- `tsm-browser-host`, the native-messaging host of the Tom Secrets Manager
  browser extension (part-browser): native messaging's framing (32-bit
  length in the machine's byte order, UTF-8 JSON, 1 MB to the browser), the
  caller's origin checked against the product's extensions, and the
  extension's requests `status`, `match`, `fill` (only an entry the page
  matches), `propose` and `openApp` turned into client requests to the
  service; the app started at an entry with `--show-entry`.
