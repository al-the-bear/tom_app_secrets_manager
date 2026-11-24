# Tom Secrets Manager browser extension

> Part of the Tom Secrets Manager by Peter Nicolai Alexis Kyaw, BSD-3-Clause.

The browser extension of the Tom Secrets Manager (part-browser): a Manifest
V3 WebExtension for Chromium browsers (Chrome, Chromium, Edge, Brave) and
Firefox, built from one TypeScript source. It shows the logins the vaults
hold for the page, fills the one you pick, and never fills by itself; it
offers to save a login you signed in with that the vaults do not hold, and
suggests a password in new-password fields. It talks only to the
native-messaging host `tsm-browser-host` (the package around this folder),
which asks the secrets service.

Using it in each browser is the [user guide](../doc/user_guide.md); this
README is the developers' reference.

## What it does

- **Finding the form.** A content script runs in every frame of every
  `http` and `https` page. It finds the user name, password and one-time
  code fields, also inside open shadow roots, by `autocomplete`
  (`username`, `current-password`, `one-time-code`), then by type, name and
  position. Hidden, disabled and read-only fields are left out, and a change
  form's new password is never filled. A split login (the user name alone
  first) counts as a login form.
- **The icons.** A small shield sits at the right edge of the user-name and
  password fields, and of the first new-password field; a click opens the
  list there (at a new-password field: a suggested password). Each icon is
  a button in a closed shadow root laid over the field; it follows the
  field when the page scrolls or resizes, hides for fields too small, and
  goes with its field.
- **Opening the list.** You open it in the field's frame with an icon, the
  shortcut Ctrl+Shift+L (Command+Shift+L on macOS), the context menu "Fill
  from Tom Secrets Manager" on a field, or the toolbar button's popup.
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
- **A suggested password** (a sign-up or password-change form, its
  `new-password` fields, or the two after a current one): the list shows a
  password from the product generator's default policy (20 characters,
  lower and upper case, digits and symbols, from the browser's CSPRNG);
  "Use this password" fills it into the form's new-password fields, in that
  frame only; "Another" makes a new one. Saving it is the proposal below.
- **Proposing a login** (DP-43). When a form with a password is submitted
  (its submit, Enter in a password field, or a sign-in button of a page
  without a form), the content script reports the user name and the
  password (the new one of a change form) once. The background asks the
  host's `check` whether the vaults hold it, which compares inside the host
  and answers no value: a login they hold brings nothing; a new login or a
  changed password brings the bar "Save in Tom Secrets Manager?" at the top
  of the tab, also on the page the form led to. It names the site and the
  user, never the password. "Save" sends `propose`: the app shows it under
  Proposals, where it is saved as a new login, updates the existing one, or
  is dropped. "Not now" drops it; "Never for this site" keeps the site off
  (the popup's "Offer to save logins on this site" turns it on again). The
  password is held in the background only until the bar is answered, the
  tab closes, or two minutes pass. Saving needs "Always in this browser":
  the service refuses a proposal from a browser without a lasting grant.
- **Its approval.** The service lists the logins a grant of the browser
  host covers. The first lookup that nothing covers asks the user in the
  app (the browser prompt, DP-44): "This time" (the logins listed and each
  filled once within ten minutes), "Always in this browser" (a grant for
  the browser that started the host, so each browser is approved on its
  own) or "Never". The list says it is asking meanwhile; with the app
  closed nothing is asked and no login is listed. System vaults are never
  served to the browser, neither their logins nor their values.
- **Passkeys** (DP-120). A script in the page's own world
  (`webauthn.js`, `world: "MAIN"`, from the page's start) takes over
  `navigator.credentials.get` and `create` for passkey requests. It hands
  them to the content script by `postMessage`.
  - **Signing in.** The background asks the host for the page's passkeys.
    When there are some, the extension's own list opens at the top right of
    the page ("Sign in to … with a passkey"). The user picks one there,
    where the page cannot reach. The background then makes the client data
    (`webauthn.get`, the frame's origin from the browser's sender
    information, never the page's word), and the service signs its hash.
    The page gets a `PublicKeyCredential` shaped as WebAuthn's.
  - **Creating one.** A creation goes to the service, which asks in the
    app ("Save a passkey for …?"). Once saved, the page gets the `none`
    attestation and the public key. A passkey the vaults hold already for
    that account is the page's `InvalidStateError`.
  - **The browser's own.** It answers everything else: conditional
    requests (the browser's own passkey autofill), a page with no passkey
    in the vaults, a locked or closed app, no host, the list closed, "Not
    now" in the app.
  - **No key.** The extension never holds a passkey's key: the service
    signs. The page may send the bridge's messages itself, which gains it
    nothing WebAuthn would not give it.
- **Who may ask.** Only the extension's own list and popup pages may ask for
  a list, a fill or a code, and only the bar page for its bar, each only for
  the token of its own. Every other sender is answered `denied`. No stored
  value ever reaches the list page; it gets the candidates only.
- **What it keeps.** The extension's storage holds the never-list (sites
  only). No password, code or entry is written to `storage`,
  `localStorage` or IndexedDB.

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
`dist/chromium/`, `dist/firefox/` and `dist/safari/`, each with its own
`manifest.json` (Chromium's and Safari's background is a service worker,
Firefox's a background script; Chromium 111, Firefox 128 and Safari 17 or
later) and its icons (16, 32, 48 and
128 pixels, drawn by `tool/icon.ts`: the repository holds no image). It
then writes the store packages into `dist/packages/`:
`tom-secrets-browser-extension-<version>-chromium.zip` and `-firefox.zip`,
whose manifest has no development `key` (the store gives the id). The ZIPs
are deterministic (`tool/zip.ts`). The Safari build has no ZIP: the macOS
app's Safari Web Extension carries it
(`tom_secrets_app/macos/TomSecretsSafari`). In Safari the background
reaches the host through the app's handler (`src/safari.ts`,
`browser.runtime.sendNativeMessage`, one session per operation); passkeys
in Safari go through the app's AutoFill provider, so the Safari build has
no page-world WebAuthn script. `tom_secrets_build`'s `ci.sh :release`
copies them beside the release archives, listed in `SHA256SUMS`.

The extension has no runtime dependency: the small `browser ?? chrome` shim in `src/api.ts` takes the
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

- the form detection, new-password fields and what a submit carries;
- the fill with its events and its retry;
- the content script's list and its fill for its own token only, its icons,
  the capture at submit, the bar and the suggestion filled;
- the list view in each state, the bar and the suggestion;
- the background's sender checks, its list contexts, the fill sent to one
  frame, the service's states, an unreachable host, a form in a frame of
  another site and the popup;
- proposals: known, new and changed logins, the bar after a navigation,
  Save, Not now, Never for this site and the popup's switch, a closed tab
  and the lifetime, a refused Save;
- passkeys: the options and the client data, the background's sign-in
  (the list, the signature sent to the one frame that asked) and creation
  (an excluded credential), the browser's own WebAuthn when nothing is
  there, the page script's take-over (conditional requests left alone) and
  the credential objects;
- the generator, the three manifests, the icons and the store packages
  read back;
- Safari's port through the app's handler: one session, the answers back,
  close, an unreachable app said.

`tom_secrets_build`'s `ci.sh` runs `npm ci`, `npm run build` (`:analyze`)
and `npm test` (`:test`), and checks the dependency closure from
`package-lock.json` (`:licences`).

## Screenshots

```text
npm run build && npm run screenshots
```

`tool/screenshots.mjs` loads a screenshot build of `dist/chromium` into
headless Chromium (Playwright; once `npx playwright install chromium`). Its
background is the extension's own over the tests' fake host, which answers
demo logins and passkeys (`tool/screenshot_background.ts`); the demo page's
path sets the service's state (`/locked`, `/notrunning`, `/nohost`,
`/asking`). The demo pages are served on 127.0.0.1 (a demo mail, from
`tool/demo_login.html`) and on localhost (a demo single sign-on, also in a
frame of the mail's portal page). It writes to `../doc/images/`:

- `shield-field`: the login form with the icons in its fields;
- `list-logins`: the in-page list at the user-name field;
- `list-locked`, `list-notrunning`, `list-nohost`: the list with the
  service locked, not running, and no host installed;
- `list-asking`: the list while the app is asked to approve the browser;
- `list-suggest`: a suggested password at a sign-up form's new-password
  field;
- `list-frame`, `list-frame-logins`: a login form in a frame of another
  site, the list offering the frame's own logins, then showing them;
- `passkey-list`: the list of a page's passkeys for a sign-in;
- `bar-save`, `bar-saved`, `bar-update`: the save bar for a new login,
  after Save, and for a changed password;
- `popup-logins`, `popup-locked`, `popup-never`: the popup with the logins,
  with the service locked, and with saving turned off for the site.

Each is `<name>-light.png`. Demo data only; no release build holds any of
it.

## Limits

- The store entries are unlisted (DP-46) and made by the user, who also
  has Mozilla sign the Firefox package (AMO signs every build, listed or
  not). Chrome on Windows and macOS installs only from its store or in
  developer mode, so the Chromium ZIP is for the store upload.
- A login whose user name and password are typed on two pages is proposed
  with the password page's user name only when that page still shows it.
- The popup fills the tab's top frame only; a login in a frame is filled
  from the list at the field.
- A page whose permissions policy forbids `clipboard-write` to its frames
  blocks Copy code in the in-page list; the popup's Copy code still works.
  The copied code stays on the clipboard until something else is copied.
- Safari needs the team-signed macOS app, which carries the extension.
- Passkeys need Chrome 111 or Firefox 128 at least (`world: "MAIN"` content
  scripts). While Tom Secrets Manager is locked a page's passkeys are the
  browser's own; the extension does not ask for an unlock then.
