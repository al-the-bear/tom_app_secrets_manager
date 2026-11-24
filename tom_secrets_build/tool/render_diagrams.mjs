// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

// The diagram export: every diagram of the Markdown files under the folders
// and files named on the command line, written as SVG and PNG to
// `<doc dir>/images/diagrams/<document>/<n>-<slug>.svg|png` in the style of
// enterprise-flutter.dev's diagrams (doc/diagram_style.md). The documents
// show the SVG; the PNG is for places that show no SVG (the Medium article).
// The files are regenerated, never edited by hand: a diagram marked
// `hand-drawn` keeps its SVG (drawn in the sample style), and only its PNG
// is written.
//
//   node tool/render_diagrams.mjs <folder or file> ...   export
//   node tool/render_diagrams.mjs --hash <folder or file> ...
//       print each diagram's source hash (a hand-drawn SVG's data-tsm-source)
//
// Writes only what is stale or missing; prints what it wrote.

import { existsSync, mkdirSync, readdirSync, readFileSync, statSync, writeFileSync } from 'node:fs';
import { dirname } from 'node:path';
import { pathToFileURL } from 'node:url';

import {
  exportedHash,
  exportPaths,
  markdownFiles,
  parseDocument,
  postProcess,
  sourceHash,
} from './docs_lib.mjs';

function diagramsUnder(roots) {
  const files = markdownFiles(roots, {
    readdir: (d) => readdirSync(d),
    statIsDir: (path) => existsSync(path) && statSync(path).isDirectory(),
  });
  return files.flatMap((file) =>
    parseDocument(readFileSync(file, 'utf8'))
      .diagrams.filter((d) => !d.missingSource)
      .map((d) => ({ file, ...d })),
  );
}

/** Exports every stale or missing diagram under [roots] with [browser];
 *  answers the paths written. [force] writes all. */
export async function exportDiagrams(roots, browser, { force = false } = {}) {
  const { renderSvg, svgToPng } = await import('./mermaid_render.mjs');
  const written = [];
  for (const d of diagramsUnder(roots)) {
    const { svg, png } = exportPaths(d.file, d.id);
    const hash = sourceHash(d.source);
    const current = existsSync(svg) && exportedHash(readFileSync(svg, 'utf8')) === hash;
    if (d.handDrawn) {
      if (!existsSync(svg)) throw new Error(`${d.file}:${d.line}: ${svg} is drawn by hand and missing`);
      if (force || !existsSync(png)) {
        writeFileSync(png, await svgToPng(browser, readFileSync(svg, 'utf8')));
        written.push(png);
      }
      continue;
    }
    if (current && existsSync(png) && !force) continue;
    const styled = postProcess(await renderSvg(browser, d.source), {
      title: d.title,
      desc: d.desc,
      hash,
    });
    mkdirSync(dirname(svg), { recursive: true });
    writeFileSync(svg, styled);
    writeFileSync(png, await svgToPng(browser, styled));
    written.push(svg, png);
  }
  return written;
}

async function main(args) {
  const hashOnly = args[0] === '--hash';
  const force = args[0] === '--force';
  const roots = hashOnly || force ? args.slice(1) : args;
  if (roots.length === 0) {
    process.stderr.write('usage: node tool/render_diagrams.mjs [--hash | --force] <folder or file> ...\n');
    return 2;
  }
  if (hashOnly) {
    for (const d of diagramsUnder(roots)) {
      process.stdout.write(`${d.file} ${d.id} ${sourceHash(d.source)}\n`);
    }
    return 0;
  }
  const { withBrowser } = await import('./mermaid_render.mjs');
  const written = await withBrowser((browser) => exportDiagrams(roots, browser, { force }));
  for (const w of written) process.stdout.write(`wrote ${w}\n`);
  process.stdout.write(`${written.length} files written\n`);
  return 0;
}

if (import.meta.url === pathToFileURL(process.argv[1]).href) {
  process.exitCode = await main(process.argv.slice(2));
}
