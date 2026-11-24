// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

// The overview's article export: the diagrams' comments left out and their
// images made absolute PNG addresses, relative links absolute, the abstract
// kept under the title, paragraphs and list items on one line, code kept;
// and the generated article folder left out of the documentation check.
// Demo documents only.

import { strict as assert } from 'node:assert';
import { describe, test } from 'node:test';

import { absoluteTarget, articleFromOverview, repositoryBlob, repositoryRaw, unwrap } from '../export_article.mjs';
import { markdownFiles } from '../docs_lib.mjs';

const overview = `# Demo product

*The abstract, which is the subtitle,
wrapped over two lines.*

## Part

A paragraph that
goes on, with the [flows](flows.md#pairing) and the
[core](../tom_secrets_core/README.md) and [this](#part).

This diagram shows the parts.

![The parts](images/diagrams/overview/1-parts.svg)

<!-- diagram 1-parts
\`\`\`mermaid
flowchart LR
  a --&gt; b
\`\`\`
-->

- an item
  that goes on
- [GitHub](https://github.com/example)

\`\`\`text
code stays
  as it is
\`\`\`
`;

describe('the article', () => {
  const { markdown, images } = articleFromOverview(overview);
  const lines = markdown.split('\n');

  test('the diagram becomes its PNG, its comment is left out', () => {
    assert.deepEqual(images, ['1-parts']);
    assert.ok(markdown.includes(`![The parts](${repositoryRaw}/doc/article/images/1-parts.png)`));
    assert.ok(!markdown.includes('mermaid'));
    assert.ok(!markdown.includes('diagram 1-parts'));
  });

  test('relative links become GitHub addresses', () => {
    assert.ok(markdown.includes(`[flows](${repositoryBlob}/doc/flows.md#pairing)`));
    assert.ok(markdown.includes(`[core](${repositoryBlob}/tom_secrets_core/README.md)`));
    assert.ok(markdown.includes(`[this](${repositoryBlob}/doc/overview.md#part)`));
    assert.ok(markdown.includes('[GitHub](https://github.com/example)'));
  });

  test('the abstract stays under the title, on one line', () => {
    const title = lines.indexOf('# Demo product');
    assert.ok(title > 0, 'a generated-file comment comes first');
    assert.equal(lines[title + 2], '*The abstract, which is the subtitle, wrapped over two lines.*');
  });

  test('paragraphs and list items are on one line; code is kept', () => {
    assert.ok(lines.some((l) => l.startsWith('A paragraph that goes on, with the [flows]')));
    assert.ok(lines.includes('- an item that goes on'));
    assert.ok(lines.includes('code stays'));
    assert.ok(lines.includes('  as it is'));
  });

  test('a link out of the repository is refused', () => {
    assert.throws(() => absoluteTarget('../../elsewhere.md'));
  });

  test('unwrap keeps tables and headings', () => {
    assert.deepEqual(unwrap(['# H', '| a |', '| - |', 'x', 'y']), ['# H', '| a |', '| - |', 'x y']);
  });
});

describe('the documentation check', () => {
  test('leaves a generated article folder out', () => {
    const tree = {
      '/d': ['overview.md', 'article'],
      '/d/article': ['overview.medium.md'],
    };
    const files = markdownFiles(['/d'], {
      readdir: (dir) => tree[dir],
      statIsDir: (path) => path in tree,
    });
    assert.deepEqual(files, ['/d/overview.md']);
  });
});
