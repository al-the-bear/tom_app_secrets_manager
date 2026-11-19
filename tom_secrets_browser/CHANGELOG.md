# Changelog

## 0.1.0

- The browser extension (`extension/`, part-browser): Manifest V3 for
  Chromium browsers and Firefox from one TypeScript source; the login
  fields found in every frame (open shadow roots too); the list of the
  page's logins in a closed shadow root at the field, opened by the
  shortcut, the context menu or the popup; the fill into the list's own
  frame only, with the events frameworks listen to; a form in a frame of
  another site offered on its own; locked, not running and no host each
  saying what to do. No runtime dependency.
- `match` takes the extension's `wait` (`false`: `locked` at once).

- `tsm-browser-host`, the native-messaging host of the Tom Secrets Manager
  browser extension (part-browser): native messaging's framing (32-bit
  length in the machine's byte order, UTF-8 JSON, 1 MB to the browser), the
  caller's origin checked against the product's extensions, and the
  extension's requests `status`, `match`, `fill` (only an entry the page
  matches), `propose` and `openApp` turned into client requests to the
  service; the app started at an entry with `--show-entry`.
