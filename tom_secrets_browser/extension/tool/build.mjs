// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

// Builds the extension per browser family into dist/<family>/: the scripts
// bundled by esbuild (a content script cannot load modules), the static
// pages, and the manifest from src/manifest.ts. `npm run build`.

import { build } from 'esbuild';
import { cpSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
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

const entries = {
  background: 'background-main.ts',
  content: 'content-main.ts',
  list: 'list.ts',
  popup: 'popup.ts',
};

for (const family of ['chromium', 'firefox']) {
  const out = join(root, 'dist', family);
  rmSync(out, { recursive: true, force: true });
  mkdirSync(out, { recursive: true });
  for (const [name, entry] of Object.entries(entries)) {
    await build({
      entryPoints: [join(root, 'src', entry)],
      bundle: true,
      format: 'iife',
      target: family === 'chromium' ? 'chrome110' : 'firefox115',
      outfile: join(out, `${name}.js`),
      legalComments: 'none',
      logLevel: 'warning',
    });
  }
  cpSync(join(root, 'static'), out, { recursive: true });
  cpSync(join(root, 'LICENSE'), join(out, 'LICENSE'));
  writeFileSync(
    join(out, 'manifest.json'),
    `${JSON.stringify(manifest(family, version), null, 2)}\n`,
  );
  process.stdout.write(`built dist/${family}\n`);
}
