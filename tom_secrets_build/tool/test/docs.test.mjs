// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

// The documentation tooling: a document's diagrams, links and long lines
// read; the check passing a document whose diagram renders and is exported,
// and failing on a diagram that does not render, a stale or missing export,
// a broken link and a long line; the export writing SVG and PNG in the
// website style. Demo documents in a temporary folder.

import { strict as assert } from 'node:assert';
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { after, before, describe, test } from 'node:test';

import { checkDocs } from '../check_docs.mjs';
import {
  exportPaths,
  maxLineLength,
  palette,
  parseDocument,
  postProcess,
  sourceHash,
  withClassDefs,
} from '../docs_lib.mjs';
import puppeteer from 'puppeteer';

import { renderSvg } from '../mermaid_render.mjs';
import { exportDiagrams } from '../render_diagrams.mjs';

const good = `flowchart LR
  a("Secrets service"):::program --> b[("Vault")]:::vault`;

function documentWith(source, { id = '1-demo', title = 'A demo diagram' } = {}) {
  return [
    '# Demo',
    '',
    'This diagram shows the service and its vault.',
    '',
    `![${title}](images/diagrams/demo/${id}.svg)`,
    '',
    `<!-- diagram ${id}`,
    '```mermaid',
    source.replace(/>/g, '&gt;'),
    '```',
    '-->',
    '',
    'The service reads the vault.',
    '',
  ].join('\n');
}

describe('reading a document', () => {
  test('a diagram: its id, title, description and source', () => {
    const parsed = parseDocument(documentWith(good));
    assert.equal(parsed.diagrams.length, 1);
    const d = parsed.diagrams[0];
    assert.equal(d.id, '1-demo');
    assert.equal(d.title, 'A demo diagram');
    assert.equal(d.desc, 'This diagram shows the service and its vault.');
    assert.equal(d.source, good);
    assert.equal(d.handDrawn, false);
    assert.deepEqual(parsed.longLines, []);
    assert.deepEqual(
      parsed.links.map((l) => l.target),
      ['images/diagrams/demo/1-demo.svg'],
    );
  });

  test('a raw "-->" in a diagram comment, which GitHub ends there, is a problem', () => {
    const escaped = parseDocument(documentWith(good));
    assert.equal(escaped.diagrams[0].rawArrowLine, undefined);
    const raw = parseDocument(documentWith(good).replace('--&gt;', '-->'));
    assert.equal(raw.diagrams[0].rawArrowLine, 10);
    assert.equal(raw.diagrams[0].source, good);
  });

  test('any other raw ">" in a diagram comment is a problem: one rule, every ">" as "&gt;"', () => {
    const escaped = parseDocument(documentWith(good));
    assert.equal(escaped.diagrams[0].rawGreaterLine, undefined);
    const raw = parseDocument(documentWith(good).replace('Secrets service', 'Secrets<br/>service'));
    assert.equal(raw.diagrams[0].rawGreaterLine, 10);
    assert.equal(raw.diagrams[0].rawArrowLine, undefined);
  });

  test('long lines: tables, code, comments and lines holding only an image '
    + 'or a link excepted', () => {
    const long = 'x'.repeat(maxLineLength + 1);
    const text = [
      `${'y'.repeat(maxLineLength)}`,
      long,
      `| ${long} |`,
      '```text',
      long,
      '```',
      '<!--',
      long,
      '-->',
      `![${long}](a.svg)`,
      `- [${long}](b.md#${long})`,
    ].join('\n');
    assert.deepEqual(parseDocument(text).longLines, [{ line: 2, length: maxLineLength + 1 }]);
  });

  test('a hand-drawn diagram, a plain mermaid fence, links of every kind', () => {
    const text = [
      '![Hand](images/diagrams/x/1-hand.svg)',
      '<!-- diagram 1-hand hand-drawn',
      '```mermaid',
      'flowchart LR',
      '  a --> b',
      '```',
      '-->',
      '```mermaid',
      'sequenceDiagram',
      '  A->>B: hi',
      '```',
      'See [the guide](guide.md#start), [the site](https://example.com),',
      '[this section](#here) and [ref].',
      '',
      '[ref]: other.md',
    ].join('\n');
    const parsed = parseDocument(text);
    assert.equal(parsed.diagrams[0].handDrawn, true);
    assert.equal(parsed.fences.length, 1);
    assert.deepEqual(
      parsed.links.map((l) => l.target),
      ['images/diagrams/x/1-hand.svg', 'guide.md#start', 'https://example.com', '#here', 'other.md'],
    );
  });

  test('flowcharts get the class set; other diagrams are left alone', () => {
    assert.match(withClassDefs(good), /classDef program fill:#0E2841/);
    assert.match(withClassDefs(good), /classDef zoneRemote /);
    const seq = 'sequenceDiagram\n  A->>B: hi';
    assert.equal(withClassDefs(seq), seq);
  });

  test('the post-processing: title, description, hash and the panel', () => {
    const svg = postProcess(
      '<svg id="x" viewBox="0 0 100 50" style="max-width: 100px;" xmlns="http://www.w3.org/2000/svg"><g/></svg>',
      { title: 'A & B', desc: 'What it shows.', hash: 'abc123' },
    );
    assert.match(svg, /role="img" aria-label="A &amp; B"/);
    assert.match(svg, /data-tsm-source="abc123"/);
    assert.match(svg, /<title>A &amp; B<\/title><desc>What it shows.<\/desc>/);
    assert.match(svg, new RegExp(`rx="22" fill="${palette.panel}"`));
    assert.doesNotMatch(svg, /max-width/);
  });

  test('the post-processing gives the SVG its own size: every viewer draws it '
    + 'at that size, not at the 300-pixel fallback of width="100%"', () => {
    const svg = postProcess(
      '<svg id="x" width="100%" viewBox="-16 -16 1035.09 300.67" style="max-width: 1035px;" xmlns="http://www.w3.org/2000/svg"><g/></svg>',
      { title: 'T', desc: 'D', hash: 'h' },
    );
    const open = svg.match(/<svg\b[^>]*>/)[0];
    assert.match(open, / width="1036"/);
    assert.match(open, / height="301"/);
    assert.doesNotMatch(open, /width="100%"/);
  });
});

describe('the check and the export, with the real renderer', () => {
  let dir;
  let browser;

  before(async () => {
    dir = mkdtempSync(join(tmpdir(), 'tsmdocs-'));
    browser = await puppeteer.launch({ headless: true });
  });

  after(async () => {
    await browser.close();
    rmSync(dir, { recursive: true, force: true });
  });

  const write = (name, text) => {
    const path = join(dir, name);
    writeFileSync(path, text);
    return path;
  };
  const check = (path) => checkDocs([path], (source) => renderSvg(browser, source));

  test('a document whose diagram renders and is exported passes', async () => {
    const doc = write('demo.md', documentWith(good));
    const written = await exportDiagrams([doc], browser);
    const { svg, png } = exportPaths(doc, '1-demo');
    assert.deepEqual(written, [svg, png]);
    const exported = readFileSync(svg, 'utf8');
    assert.match(exported, /<title>A demo diagram<\/title>/);
    assert.match(exported, /data-tsm-source="[0-9a-f]{16}"/);
    assert.match(exported, /font-family="Inter/);
    assert.doesNotMatch(exported, /foreignObject/);
    assert.equal(readFileSync(png).subarray(1, 4).toString(), 'PNG');

    const result = await check(doc);
    assert.deepEqual(result.problems, []);
    assert.equal(result.diagrams, 1);
    // Exported again only when stale.
    assert.deepEqual(await exportDiagrams([doc], browser), []);
  });

  test('a diagram that does not render fails the check', async () => {
    const doc = write('broken.md', documentWith('flowchart LR\n  a --> (( b'));
    const result = await check(doc);
    assert.ok(
      result.problems.some((p) => /diagram 1-demo does not render/.test(p)),
      result.problems.join('\n'),
    );
  });

  test('a missing or stale export, a broken link and a long line fail it', async () => {
    const stale = write('stale.md', documentWith(good, { id: '1-stale' }));
    mkdirSync(join(dir, 'images', 'diagrams', 'stale'), { recursive: true });
    const { svg, png } = exportPaths(stale, '1-stale');
    writeFileSync(svg, '<svg data-tsm-source="0000000000000000"></svg>');
    writeFileSync(png, '');
    const missing = write('missing.md', `${documentWith(good, { id: '1-new' })}\n[gone](nowhere.md)\n${'z'.repeat(81)}\n`);
    const result = await checkDocs([stale, missing], (source) => renderSvg(browser, source));
    const text = result.problems.join('\n');
    assert.match(text, /stale\.md:7: diagram 1-stale's SVG is older than its source/);
    assert.match(text, /missing\.md:7: diagram 1-new is not exported/);
    assert.match(text, /missing\.md:\d+: link to nowhere\.md, which does not exist/);
    assert.match(text, /missing\.md:\d+: line of 81 characters/);
    assert.notEqual(sourceHash(good), '0000000000000000');
  });
});
