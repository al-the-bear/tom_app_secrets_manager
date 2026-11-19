# Tom Secrets Manager browser extension

> Part of the Tom Secrets Manager by Peter Nicolai Alexis Kyaw, BSD-3-Clause.

The browser extension of the Tom Secrets Manager (part-browser): a Manifest
V3 WebExtension for Chromium browsers (Chrome, Chromium, Edge, Brave) and
Firefox, built from one TypeScript source. It shows the logins the vaults
hold for the page, fills the one you pick, and never fills by itself. It
talks only to the native-messaging host `tsm-browser-host` (the package
around this folder), which asks the secrets service.

## What it does

- **Finding the form.** A content script runs in every frame of every
  `http` and `https` page. It finds the user name, password and one-time
  code fields, also inside open shadow roots, by `autocomplete`
  (`username`, `current-password`, `one-time-code`), then by type, name and
  position. Hidden, disabled and read-only fields are left out, and a change
  form's new password is never filled. A split login (the user name alone
  first) counts as a login form.
- **Opening the list.** You open it in the field's frame with the shortcut
  Ctrl+Shift+L (Command+Shift+L on macOS), from the context menu "Fill from
  Tom Secrets Manager" on a field, or from the toolbar button's popup.
- **The list** is the extension's own page in an iframe, in a closed shadow
  root at the field, so the page can neither read nor restyle it. It shows
  each login of the site (title, user name, the address it matched) with
  Fill, Copy code (when the entry has a TOTP) and a filter once there are
  more than five. When the service is locked it offers "Unlock in Tom
  Secrets Manager" and waits for the unlock. When the service is not
  running it offers "Open Tom Secrets Manager". When no host is installed it
  says so and points to the app's Settings › Integrations › Browsers.
  Escape closes it.
- **Matching** is the service's: the background sends the address of the
  page and of the frame as the browser reports them (`sender.url`,
  `tab.url`), never what the page says. A login form in a frame of another
  site matches nothing at first; the list then offers "Show the logins of
  `<frame site>`" and matches that frame on its own.
- **The fill** goes only to the frame the list was opened for. The host
  reads the values only for an entry the page matches. The content script
  sets each value through the input's own value setter and sends `input` and
  `change`, so React, Vue and Angular see it. When the page cleared a value
  within 300 ms, it types it once more with key events. The TOTP is filled
  when the form has a one-time-code field. A list's token is spent by its
  fill, and a list lives 10 minutes at most.
- **Its approval.** The service lists only the logins a grant of the
  browser host covers and does not ask for one; the user approves
  `tsm-browser-host` once in the app's Clients › Pre-approve (the app's
  user guide). System vaults are never served to the browser.
- **Who may ask.** Only the extension's own list and popup pages may ask for
  a list, a fill or a code, and only for the token of their own list. Every
  other sender is answered `denied`. No value ever reaches the list page; it
  gets the candidates only.

The permissions are `nativeMessaging`, `activeTab`, `scripting`, `storage`
and `contextMenus`, with host permission `<all_urls>` for the content
script (DP-45). The ids are fixed:

- Chromium: the manifest's `key` gives the development build the id
  `lcejninmlbnhfnpedlgjjfeelhbgmach`;
- Firefox: the gecko id `tom-secrets@enterprise-flutter.dev`.

The host admits only these (`tom_secrets_client`'s
`tomSecretsChromiumExtensionIds`, `tomSecretsFirefoxExtensionId`);
`test/extension_ids_test.dart` in the package checks that the source names
the same ones.

## Building

```text
npm ci
npm run build
```

This type-checks the source and bundles it with esbuild into
`dist/chromium/` and `dist/firefox/`, each with its own `manifest.json`
(Chromium's background is a service worker, Firefox's a background script;
Firefox 115 or later, Chromium 110 or later). The extension has no runtime
dependency: the small `browser ?? chrome` shim in `src/api.ts` takes the
place of `webextension-polyfill`, which is MPL-2.0.

To try a build, load it unpacked:

- Chromium browsers: `chrome://extensions` (or `edge://extensions`),
  Developer mode, "Load unpacked", choose `dist/chromium`;
- Firefox: `about:debugging#/runtime/this-firefox`, "Load Temporary
  Add-on…", choose `dist/firefox/manifest.json`.

Then turn the browser on in the desktop app's Settings › Integrations ›
Browsers, which installs the host's manifest for it.

## Testing

```text
npm test
```

The tests (node:test, with jsdom for the page) cover:

- the form detection;
- the fill with its events and its retry;
- the content script's list and its fill for its own token only;
- the list view in each state;
- the background's sender checks, its list contexts, the fill sent to one
  frame, the service's states, an unreachable host, a form in a frame of
  another site and the popup;
- both manifests.

`tom_secrets_build`'s `ci.sh` runs `npm ci`, `npm run build` (`:analyze`)
and `npm test` (`:test`), and checks the dependency closure from
`package-lock.json` (`:licences`).

## Limits

- No in-field icons, saving a typed login (proposals) or store packages
  yet: they are the next step.
- The browser host's grant is made by hand (Clients › Pre-approve); the
  extension cannot ask for it.
- The popup fills the tab's top frame only; a login in a frame is filled
  from the list at the field.
- A page whose permissions policy forbids `clipboard-write` to its frames
  blocks Copy code in the in-page list; the popup's Copy code still works.
  The copied code stays on the clipboard until something else is copied.
- Safari is phase C.
