# Changelog

## 0.1.0

- `tsm-browser-host`, the native-messaging host of the Tom Secrets Manager
  browser extension (part-browser): native messaging's framing (32-bit
  length in the machine's byte order, UTF-8 JSON, 1 MB to the browser), the
  caller's origin checked against the product's extensions, and the
  extension's requests `status`, `match`, `fill` (only an entry the page
  matches), `propose` and `openApp` turned into client requests to the
  service; the app started at an entry with `--show-entry`.
