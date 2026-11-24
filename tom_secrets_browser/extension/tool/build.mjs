// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

// Builds the extension per browser family into dist/<family>/ (chromium,
// firefox, and safari, which the macOS app's Safari Web Extension carries):
// the scripts
// bundled by esbuild (a content script cannot load modules), the static
// pages, the icons (tool/icon.ts) and the manifest from src/manifest.ts;
// then the store packages into dist/packages/: one ZIP per family, its
// manifest without the development `key` (the store gives the id).
// `npm run build`.

import { build } from 'esbuild';
import {
  cpSync,
  mkdirSync,
  readdirSync,
  readFileSync,
  rmSync,
  statSync,
  writeFileSync,
} from 'node:fs';
import { dirname, join, relative, sep } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const { version } = JSON.parse(readFileSync(join(root, 'package.json'), 'utf8'));

// The manifest module, bundled for this script.
const manifestModule = join(root, 'build', 'manifest.mjs');
await build({
  entryPoints: [join(root, 'src', 'manifest.ts')],
  bundle: true,
  format: 'esm',
  platform: 'node',
  outfile: manifestModule,
  logLevel: 'warning',
});
const { manifest } = await import(pathToFileURL(manifestModule).href);

// The icon and ZIP writers, bundled for this script.
const toolsModule = join(root, 'build', 'tools.mjs');
await build({
  stdin: {
    contents: "export { iconPng, iconSizes } from './icon'; export { zip } from './zip';",
    resolveDir: join(root, 'tool'),
    loader: 'ts',
  },
  bundle: true,
  format: 'esm',
  platform: 'node',
  outfile: toolsModule,
  logLevel: 'warning',
});
const { iconPng, iconSizes, zip } = await import(pathToFileURL(toolsModule).href);

/** Every file below [dir], by its path relative to it with `/`. */
function filesOf(dir) {
  const out = new Map();
  const walk = (d) => {
    for (const name of readdirSync(d)) {
      const path = join(d, name);
      if (statSync(path).isDirectory()) walk(path);
      else out.set(relative(dir, path).split(sep).join('/'), readFileSync(path));
    }
  };
  walk(dir);
  return out;
}

const packages = join(root, 'dist', 'packages');
rmSync(packages, { recursive: true, force: true });
mkdirSync(packages, { recursive: true });

const entries = {
  background: 'background-main.ts',
  content: 'content-main.ts',
  list: 'list.ts',
  popup: 'popup.ts',
  bar: 'bar.ts',
  webauthn: 'webauthn-main.ts',
};

/** The scripts of [family]: Safari's background reaches the host through
 *  the app's handler, and Safari has no page-world WebAuthn script. */
function entriesOf(family) {
  if (family !== 'safari') return entries;
  const { webauthn: _, ...rest } = entries;
  return { ...rest, background: 'background-safari.ts' };
}

const targets = { chromium: 'chrome111', firefox: 'firefox128', safari: 'safari17' };

for (const family of ['chromium', 'firefox', 'safari']) {
  const out = join(root, 'dist', family);
  rmSync(out, { recursive: true, force: true });
  mkdirSync(out, { recursive: true });
  for (const [name, entry] of Object.entries(entriesOf(family))) {
    await build({
      entryPoints: [join(root, 'src', entry)],
      bundle: true,
      format: 'iife',
      target: targets[family],
      outfile: join(out, `${name}.js`),
      legalComments: 'none',
      logLevel: 'warning',
    });
  }
  cpSync(join(root, 'static'), out, { recursive: true });
  cpSync(join(root, 'LICENSE'), join(out, 'LICENSE'));
  mkdirSync(join(out, 'icons'), { recursive: true });
  for (const size of iconSizes) {
    writeFileSync(join(out, 'icons', `icon-${size}.png`), iconPng(size));
  }
  writeFileSync(
    join(out, 'manifest.json'),
    `${JSON.stringify(manifest(family, version), null, 2)}\n`,
  );
  process.stdout.write(`built dist/${family}\n`);
  // Safari's build goes into the macOS app, not into a store package.
  if (family === 'safari') continue;
  const files = filesOf(out);
  files.set(
    'manifest.json',
    Buffer.from(`${JSON.stringify(manifest(family, version, { store: true }), null, 2)}\n`),
  );
  const name = `tom-secrets-browser-extension-${version}-${family}.zip`;
  writeFileSync(join(packages, name), zip(files));
  process.stdout.write(`packed dist/packages/${name}\n`);
}
