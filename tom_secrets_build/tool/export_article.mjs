// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

// The overview as a Medium article (doc/README.md, "The overview as an
// article"): reads `<doc>/overview.md` and writes
// `<doc>/article/overview.medium.md` with the diagrams' PNGs beside it in
// `<doc>/article/images/`:
//
// - each diagram's SVG image becomes its PNG, as an absolute address (Medium
//   fetches images by URL), and its Mermaid comment is left out;
// - every relative link becomes an absolute GitHub address in the
//   tom_secrets_manager repository; a link to a heading of the overview
//   itself points at the overview on GitHub (Medium has no anchors);
// - the italic paragraph under the title (the abstract) stays there, as the
//   article's subtitle;
// - each paragraph and list item is joined onto one line, as Medium's editor
//   takes pasted text.
//
//   node tool/export_article.mjs <doc folder>           write
//   node tool/export_article.mjs --check <doc folder>   fail when stale
//
// The diagrams must be exported first (tool/render_diagrams.mjs): a missing
// or stale PNG is refused.

import { copyFileSync, existsSync, mkdirSync, readdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { join, posix, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

import { exportedHash, exportPaths, parseDocument, sourceHash } from './docs_lib.mjs';

/** The repository's address on GitHub, for links. */
export const repositoryBlob = 'https://github.com/al-the-bear/tom_secrets_manager/blob/main';

/** Where GitHub serves the repository's files raw, for images. */
export const repositoryRaw = 'https://raw.githubusercontent.com/al-the-bear/tom_secrets_manager/main';

/** The article's file and its images' folder, relative to the doc folder. */
export const articleFile = 'article/overview.medium.md';
export const articleImages = 'article/images';

const marker =
  '<!-- Generated from doc/overview.md by tom_secrets_build/tool/export_article.mjs: ' +
  'edit the overview and export again. -->';

/** The absolute address of [target], a link of a document in `doc/` of the
 *  repository: a relative path resolved from `doc/`, an anchor of the
 *  overview pointing at the overview. Other targets are returned as they
 *  are. */
export function absoluteTarget(target) {
  if (/^[a-z][a-z0-9+.-]*:/i.test(target)) return target;
  if (target.startsWith('#')) return `${repositoryBlob}/doc/overview.md${target}`;
  const [path, anchor] = target.split('#');
  const inRepository = posix.normalize(posix.join('doc', path));
  if (inRepository.startsWith('..')) {
    throw new Error(`the link ${target} leaves the repository`);
  }
  return `${repositoryBlob}/${inRepository}${anchor === undefined ? '' : `#${anchor}`}`;
}

/** [lines] with every paragraph and list item joined onto one line; code,
 *  tables, headings and blank lines kept. */
export function unwrap(lines) {
  const out = [];
  let inCode = false;
  const opensBlock = (l) => /^(#|\||```|~~~|>|!\[|<)/.test(l.trim());
  const isItem = (l) => /^\s*([-*]|\d+\.)\s/.test(l);
  for (const line of lines) {
    if (/^\s*(```|~~~)/.test(line)) {
      inCode = !inCode;
      out.push(line);
      continue;
    }
    if (inCode || line.trim() === '' || opensBlock(line) || isItem(line)) {
      out.push(line);
      continue;
    }
    const previous = out.length ? out[out.length - 1] : '';
    const joinable =
      previous.trim() !== '' &&
      !/^(#|\||```|~~~|!\[|<)/.test(previous.trim()) &&
      !inCode;
    if (joinable) out[out.length - 1] = `${previous.trimEnd()} ${line.trim()}`;
    else out.push(line);
  }
  return out;
}

/** The article made of the overview's [text]: `{markdown, images}`, the
 *  images the diagrams' ids whose PNGs it shows. */
export function articleFromOverview(text) {
  const parsed = parseDocument(text);
  const images = parsed.diagrams.map((d) => d.id);
  const byImage = new Map(parsed.diagrams.map((d) => [d.image, d.id]));
  // The diagrams' comments (and any other HTML comment) are left out.
  const withoutComments = text.replace(/<!--[\s\S]*?-->\n?/g, '');
  const linked = withoutComments.split('\n').map((line) =>
    line.replace(/(!?)\[([^\]]*)\]\(([^)\s]+)\)/g, (_, bang, label, target) => {
      const id = bang ? byImage.get(target) : undefined;
      const to = id ? `${repositoryRaw}/doc/${articleImages}/${id}.png` : absoluteTarget(target);
      return `${bang}[${label}](${to})`;
    }),
  );
  const lines = unwrap(linked);
  // At most one blank line in a row, where a comment was taken out.
  const tidy = lines.filter((l, i) => !(l.trim() === '' && (lines[i - 1] ?? '').trim() === ''));
  return { markdown: `${marker}\n\n${tidy.join('\n').trim()}\n`, images };
}

/** Writes (or with [check] compares) the article of the overview in [doc];
 *  answers the problems found. */
export function exportArticle(doc, { check = false } = {}) {
  const overview = join(doc, 'overview.md');
  const text = readFileSync(overview, 'utf8');
  const parsed = parseDocument(text);
  const problems = [];
  for (const d of parsed.diagrams) {
    const { svg, png } = exportPaths(overview, d.id);
    if (!existsSync(svg) || !existsSync(png) || exportedHash(readFileSync(svg, 'utf8')) !== sourceHash(d.source)) {
      problems.push(`diagram ${d.id} is not exported or stale: run tool/render_diagrams.mjs`);
    }
  }
  if (problems.length) return problems;
  const { markdown, images } = articleFromOverview(text);
  const file = join(doc, articleFile);
  const imageDir = join(doc, articleImages);
  if (check) {
    if (!existsSync(file) || readFileSync(file, 'utf8') !== markdown) {
      problems.push(`${file} is not the current overview: run tool/export_article.mjs`);
    }
    for (const id of images) {
      const copy = join(imageDir, `${id}.png`);
      const { png } = exportPaths(overview, id);
      if (!existsSync(copy) || !readFileSync(copy).equals(readFileSync(png))) {
        problems.push(`${copy} is not the current PNG: run tool/export_article.mjs`);
      }
    }
    const stray = existsSync(imageDir)
      ? readdirSync(imageDir).filter((n) => !images.includes(n.replace(/\.png$/, '')))
      : [];
    for (const name of stray) problems.push(`${join(imageDir, name)} is no diagram of the overview`);
    return problems;
  }
  rmSync(imageDir, { recursive: true, force: true });
  mkdirSync(imageDir, { recursive: true });
  for (const id of images) copyFileSync(exportPaths(overview, id).png, join(imageDir, `${id}.png`));
  writeFileSync(file, markdown);
  return problems;
}

if (import.meta.url === pathToFileURL(process.argv[1]).href) {
  const args = process.argv.slice(2);
  const check = args.includes('--check');
  const docs = args.filter((a) => a !== '--check');
  if (docs.length !== 1) {
    process.stderr.write('usage: node tool/export_article.mjs [--check] <doc folder>\n');
    process.exit(2);
  }
  const doc = resolve(docs[0]);
  const problems = exportArticle(doc, { check });
  for (const p of problems) process.stdout.write(`${p}\n`);
  if (problems.length) process.exit(1);
  process.stdout.write(check ? 'the article is current\n' : `wrote ${join(doc, articleFile)}\n`);
}
