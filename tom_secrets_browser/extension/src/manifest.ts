// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

// The extension's manifest per browser family, from one source (part-browser,
// "What it consists of"): a Chromium build with a background service worker
// and the development key that fixes its id, and a Firefox build with a
// background script and its gecko id. The ids are the ones the host serves
// (tom_secrets_client's tomSecretsChromiumDevelopmentKey and
// tomSecretsFirefoxExtensionId; a test of tom_secrets_browser compares them).

/** The browser families built. */
export type Family = 'chromium' | 'firefox';

/** The Chromium development build's public key (the manifest's `key`). */
export const chromiumDevelopmentKey =
  'MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEA0ZF3hVaz8f+yL/A28NvNBTBtbTkK' +
  '1Mxrk138GVW3nFHVT1947v5f6cqwZFViQ8txUXVIQotWjGkeX9rKx6LAvf04kJdLU5wZmwNp' +
  't8EMnWg+lHDEPr4BBbDfrcY0M5QNIGn33gXFF0z2aMjmecmI1NYmKEnPgXUW2mq4Sm+qeYlW' +
  'bHx8biUf5cmgx6HPSCq1yW1B0E1hnTKrsm84i2UKDvrZRsVvIzOTV6krjjRn2lL7Ne7oUkcf' +
  '4gQ/Den+a+L0+7VPnlv5bJoVVNlZUC+kfL+IVoVSIXdnnuognLC0Adm9o0xpenkeDVPaQv6r' +
  'XW0iFIwNlfHV3dd9KBlaVC7YxwIDAQAB';

/** The Firefox extension's id. */
export const firefoxExtensionId = 'tom-secrets@enterprise-flutter.dev';

/** The pages a content script may show in its frame. */
const pages = ['http://*/*', 'https://*/*'];

/** The icon files by size (written by the build, tool/icon.ts). */
export const icons: Record<string, string> = Object.fromEntries(
  [16, 32, 48, 128].map((size) => [String(size), `icons/icon-${size}.png`]),
);

/** The manifest of [family] at [version]. [store]: the package uploaded to
 *  the store, without the development build's `key` (the store gives the
 *  id; the Chrome Web Store refuses a `key`). */
export function manifest(
  family: Family,
  version: string,
  { store = false }: { store?: boolean } = {},
): Record<string, unknown> {
  return {
    manifest_version: 3,
    name: 'Tom Secrets Manager',
    short_name: 'Tom Secrets',
    version,
    description:
      'Fills logins from your Tom Secrets Manager vaults: the logins of the ' +
      'site from the desktop app, never filled without your click.',
    homepage_url: 'https://enterprise-flutter.dev',
    ...(family === 'chromium' && !store ? { key: chromiumDevelopmentKey } : {}),
    icons,
    // DP-45: host access to all sites, for the list at the fields.
    permissions: ['nativeMessaging', 'activeTab', 'scripting', 'storage', 'contextMenus'],
    host_permissions: ['<all_urls>'],
    background:
      family === 'chromium' ? { service_worker: 'background.js' } : { scripts: ['background.js'] },
    content_scripts: [
      { matches: pages, js: ['content.js'], all_frames: true, run_at: 'document_idle' },
      // Passkeys (DP-120): the page's WebAuthn calls, in the page's world
      // from its start, before the page's own scripts take a reference.
      {
        matches: pages,
        js: ['webauthn.js'],
        all_frames: true,
        run_at: 'document_start',
        world: 'MAIN',
      },
    ],
    action: { default_popup: 'popup.html', default_title: 'Tom Secrets Manager', default_icon: icons },
    commands: {
      'open-list': {
        suggested_key: { default: 'Ctrl+Shift+L', mac: 'Command+Shift+L' },
        description: 'Show the logins for the field',
      },
    },
    web_accessible_resources: [
      { resources: ['list.html', 'list.js', 'bar.html', 'bar.js', 'view.css'], matches: pages },
    ],
    ...(family === 'firefox'
      ? {
          browser_specific_settings: {
            gecko: { id: firefoxExtensionId, strict_min_version: '128.0' },
          },
        }
      : { minimum_chrome_version: '111' }),
  };
}
