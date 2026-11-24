// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

// The documentation check (`ci.sh :docs`): for every Markdown file under the
// folders and files named on the command line,
//
// - every diagram's Mermaid source (in its `<!-- diagram ... -->` comment)
//   and every other ```mermaid fence renders;
// - every diagram's SVG and PNG are there and current (the SVG's
//   `data-tsm-source` is its source's hash);
// - every relative link and image resolves;
// - no line is longer than 80 characters (tables, code, comments and lines
//   that hold only an image or a link excepted).
//
//   node tool/check_docs.mjs <folder or file> ...
//
// Prints each problem as `<file>:<line>: <what>` and the count; exits 1 when
// there is one, 2 on a usage error.

import { existsSync, readdirSync, readFileSync, statSync } from 'node:fs';
import { pathToFileURL } from 'node:url';

import { markdownFiles, parseDocument, staticProblems } from './docs_lib.mjs';

/** The problems of the documents under [roots]; [render] renders a Mermaid
 *  source (throws when it cannot). */
export async function checkDocs(roots, render) {
  const problems = [];
  const files = markdownFiles(roots, {
    readdir: (d) => readdirSync(d),
    statIsDir: (path) => existsSync(path) && statSync(path).isDirectory(),
  });
  let diagrams = 0;
  for (const file of files) {
    if (!existsSync(file)) {
      problems.push(`${file}: not found`);
      continue;
    }
    const parsed = parseDocument(readFileSync(file, 'utf8'));
    problems.push(...staticProblems(file, parsed));
    const sources = [
      ...parsed.diagrams.filter((d) => !d.missingSource).map((d) => ({ source: d.source, line: d.line, what: `diagram ${d.id}` })),
      ...parsed.fences.map((f) => ({ source: f.source, line: f.line, what: 'mermaid block' })),
    ];
    for (const s of sources) {
      diagrams++;
      try {
        await render(s.source);
      } catch (e) {
        problems.push(`${file}:${s.line}: ${s.what} does not render: ${String(e.message).split('\n')[0]}`);
      }
    }
  }
  return { files: files.length, diagrams, problems };
}

async function main(args) {
  if (args.length === 0) {
    process.stderr.write('usage: node tool/check_docs.mjs <folder or file> ...\n');
    return 2;
  }
  const { withBrowser, renderSvg } = await import('./mermaid_render.mjs');
  const result = await withBrowser((browser) =>
    checkDocs(args, (source) => renderSvg(browser, source)),
  );
  for (const p of result.problems) process.stdout.write(`${p}\n`);
  process.stdout.write(
    `${result.files} documents, ${result.diagrams} diagrams rendered, ` +
      `${result.problems.length} problems\n`,
  );
  return result.problems.length === 0 ? 0 : 1;
}

if (import.meta.url === pathToFileURL(process.argv[1]).href) {
  process.exitCode = await main(process.argv.slice(2));
}
