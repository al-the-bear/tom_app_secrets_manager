// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

// The documentation tooling's shared part (tom_secrets_manager's doc/README.md,
// "How these documents are written"):
//
// - a diagram is its exported SVG in the document, an image whose alt text is
//   its title, with its Mermaid source in an HTML comment right after it
//   (`<!-- diagram <n>-<slug>` ... a ```mermaid fence ... `-->`), which GitHub
//   does not render; every `>` of the source is written `&gt;`, since a line
//   holding `-->` ends the comment; the paragraph before the image says what
//   it shows;
// - the export renders the source with the light theme of enterprise-flutter.dev's
//   diagrams and post-processes the SVG (the panel, the fonts, `<title>`,
//   `<desc>`, the source's hash);
// - the check renders every source, and checks the exported files are there
//   and current, the relative links, and the line lengths.

import { createHash } from 'node:crypto';
import { existsSync, readFileSync } from 'node:fs';
import { basename, dirname, join, resolve } from 'node:path';

/** The longest line of a document; tables, code, comments and lines that
 *  hold only an image or a link are excepted. */
export const maxLineLength = 80;

/** Changes when the theme or the post-processing changes: every exported
 *  diagram is then stale and is exported again. */
export const styleVersion = 4;

/** The font stack of enterprise-flutter.dev's diagrams. */
export const fontFamily = 'Inter, -apple-system, "Segoe UI", Roboto, sans-serif';

/** The palette of enterprise-flutter.dev's diagrams (doc/diagram_style.md). */
export const palette = {
  navy: '#0E2841',
  slate: '#41576C',
  panel: '#F4F8FB',
  white: '#FFFFFF',
  border: '#D7E1EA',
  zoneBorder: '#C9D8E4',
  teal: '#156082',
  blue: '#0F7FB0',
  deepBlue: '#1B4B70',
  magenta: '#A02B93',
  magentaText: '#7A2186',
  green: '#1F7A2E',
  greenFill: '#E7F6EC',
  greenBorder: '#9ED9AE',
  amberFill: '#FFF7ED',
  amberBorder: '#F3D6BE',
  lilacFill: '#F3ECF7',
  lilacBorder: '#C9B6D8',
  skyFill: '#EAF4FA',
  skyBorder: '#BFD9EA',
  sandFill: '#F1EFE8',
  sandBorder: '#D3D1C7',
  paleBlue: '#B9CCDC',
};

/** The Mermaid configuration of the export: the `base` theme with the
 *  palette, as close to the websites' hand-drawn diagrams as Mermaid allows. */
export const mermaidConfig = {
  theme: 'base',
  // The classic look: the samples have no drop shadows.
  look: 'classic',
  // SVG text, not HTML: GitHub shows the SVG through <img>, and other
  // viewers do not render foreignObject.
  htmlLabels: false,
  // A label breaks where the source says (<br/>), not in the middle of a
  // name.
  markdownAutoWrap: false,
  fontFamily,
  themeVariables: {
    fontFamily,
    fontSize: '14px',
    background: palette.panel,
    primaryColor: palette.white,
    primaryTextColor: palette.navy,
    primaryBorderColor: palette.border,
    secondaryColor: palette.skyFill,
    tertiaryColor: palette.white,
    lineColor: palette.slate,
    textColor: palette.navy,
    clusterBkg: palette.white,
    clusterBorder: palette.zoneBorder,
    edgeLabelBackground: palette.panel,
    titleColor: palette.navy,
    nodeTextColor: palette.navy,
    actorBkg: palette.navy,
    actorTextColor: palette.white,
    actorBorder: palette.navy,
    actorLineColor: palette.slate,
    signalColor: palette.slate,
    signalTextColor: palette.navy,
    noteBkgColor: palette.amberFill,
    noteBorderColor: palette.amberBorder,
    noteTextColor: palette.navy,
    labelBoxBkgColor: palette.white,
    labelBoxBorderColor: palette.border,
    sequenceNumberColor: palette.white,
  },
  flowchart: {
    curve: 'basis',
    padding: 14,
    nodeSpacing: 46,
    rankSpacing: 52,
    htmlLabels: false,
    diagramPadding: 28,
    // Labels break only where the source says.
    wrappingWidth: 480,
  },
  sequence: { mirrorActors: false, actorMargin: 60, messageFontWeight: 600 },
  themeCSS: [
    `.node rect, .node polygon, .node path, .node circle { rx: 12px; ry: 12px; stroke-width: 1.6px; }`,
    `.edgePath .path, .flowchart-link { stroke-width: 1.6px; }`,
    `.cluster rect { rx: 18px; ry: 18px; stroke-width: 1.6px; }`,
    `.cluster-label .nodeLabel, .cluster-label text { font-weight: 700; letter-spacing: .04em; text-transform: uppercase; font-size: 13px; }`,
    `.nodeLabel, .node text, .node tspan { font-weight: 600 !important; }`,
    `.cluster-label tspan { font-weight: 700 !important; }`,
    `.edgeLabel, .edgeLabel text, .edgeLabel tspan { font-size: 11.5px; fill: ${palette.slate}; color: ${palette.slate}; font-weight: 400 !important; }`,
    `.edgeLabel rect, .labelBkg { opacity: 1 !important; fill: ${palette.panel} !important; }`,
    `.node, .cluster, .node rect, .node path, .node polygon, .cluster rect { filter: none !important; }`,
    // Dashed edges are the authorisation and key paths (magenta, as the samples).
    `.edge-pattern-dotted, .edge-pattern-dashed { stroke: ${palette.magenta} !important; stroke-dasharray: 6 5 !important; }`,
    `marker path { fill: ${palette.slate}; stroke: ${palette.slate}; }`,
  ].join('\n'),
};

/** The class set every diagram uses (doc/README.md, "Diagrams"): the same
 *  thing looks the same everywhere. Each document's Mermaid source may name
 *  them; the export defines them for every flowchart. */
export const classDefs = {
  program: `fill:${palette.navy},color:#fff,stroke:${palette.navy}`,
  library: `fill:${palette.teal},color:#fff,stroke:${palette.teal}`,
  client: `fill:${palette.skyFill},color:${palette.navy},stroke:${palette.skyBorder}`,
  file: `fill:${palette.amberFill},color:${palette.navy},stroke:${palette.amberBorder}`,
  vault: `fill:${palette.greenFill},color:${palette.green},stroke:${palette.greenBorder}`,
  key: `fill:${palette.lilacFill},color:${palette.magentaText},stroke:${palette.lilacBorder}`,
  external: `fill:#fff,color:${palette.navy},stroke:${palette.border}`,
  person: `fill:${palette.skyFill},color:${palette.navy},stroke:${palette.skyBorder}`,
  zoneDevice: `fill:#fff,color:${palette.navy},stroke:${palette.zoneBorder}`,
  zoneSandbox: `fill:${palette.amberFill},color:${palette.navy},stroke:${palette.amberBorder}`,
  zoneRemote: `fill:${palette.sandFill},color:${palette.navy},stroke:${palette.sandBorder}`,
};

/** [source] with the class set added when it is a flowchart. */
export function withClassDefs(source) {
  const first = source.trimStart().split('\n')[0];
  if (!/^(flowchart|graph)\b/.test(first)) return source;
  const defs = Object.entries(classDefs)
    .map(([name, style]) => `  classDef ${name} ${style}`)
    .join('\n');
  return `${source.trimEnd()}\n${defs}\n`;
}

/** The hash an exported SVG carries of its [source] and the style. */
export function sourceHash(source) {
  return createHash('sha256')
    .update(`style ${styleVersion}\n${source.trim()}\n`)
    .digest('hex')
    .slice(0, 16);
}

/** Markdown text without its markup, for `<desc>`. */
export function plainText(markdown) {
  return markdown
    .replace(/!\[([^\]]*)\]\([^)]*\)/g, '$1')
    .replace(/\[([^\]]*)\]\([^)]*\)/g, '$1')
    .replace(/[`*_]/g, '')
    .replace(/\s+/g, ' ')
    .trim();
}

function escapeXml(text) {
  return text
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');
}

/**
 * The parts of a Markdown document the tools read:
 * - `diagrams`: `{id, title, desc, source, handDrawn, image, line}` per
 *   `<!-- diagram <id> [hand-drawn]` comment holding a ```mermaid fence,
 *   its `&gt;` read as `>` (and `rawArrowLine`, a line of the fence holding
 *   `-->`, which would end the comment on GitHub);
 * - `fences`: the other ```mermaid fences `{source, line}`;
 * - `links`: `{target, line}` of every relative link and image outside code
 *   and comments;
 * - `longLines`: `{line, length}` over [maxLineLength], tables, code,
 *   comments and lines that hold only an image or a link excepted.
 */
export function parseDocument(text) {
  const lines = text.split('\n');
  const diagrams = [];
  const fences = [];
  const links = [];
  const longLines = [];
  let inCode = false;
  let codeLang = '';
  let codeStart = 0;
  let codeLines = [];
  let inComment = false;
  let comment = null;

  const paragraphBefore = (index) => {
    // The image's line, then the paragraph before it.
    let i = index - 1;
    while (i >= 0 && lines[i].trim() === '') i--;
    const end = i;
    while (i >= 0 && lines[i].trim() !== '') i--;
    return lines.slice(i + 1, end + 1).join(' ');
  };

  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    const lineNo = i + 1;
    const fence = line.match(/^\s*(```+|~~~+)\s*([\w-]*)/);

    if (inComment) {
      if (fence) {
        if (!inCode) {
          inCode = true;
          codeLang = fence[2];
          codeStart = lineNo;
          codeLines = [];
        } else {
          inCode = false;
          if (comment && codeLang === 'mermaid') comment.source = codeLines.join('\n');
        }
        continue;
      }
      if (inCode) {
        // GitHub ends an HTML comment at the first line holding `-->`, a
        // fence's too, so the source writes every `>` as `&gt;`.
        if (comment && line.includes('-->')) comment.rawArrowLine ??= lineNo;
        codeLines.push(codeLang === 'mermaid' ? line.replace(/&gt;/g, '>') : line);
        continue;
      }
      if (line.includes('-->')) {
        inComment = false;
        if (comment) {
          if (comment.source !== undefined) diagrams.push(comment);
          else diagrams.push({ ...comment, source: '', missingSource: true });
        }
        comment = null;
      }
      continue;
    }

    if (inCode) {
      if (fence) {
        inCode = false;
        if (codeLang === 'mermaid') fences.push({ source: codeLines.join('\n'), line: codeStart });
      } else {
        codeLines.push(line);
      }
      continue;
    }
    if (fence) {
      inCode = true;
      codeLang = fence[2];
      codeStart = lineNo;
      codeLines = [];
      continue;
    }

    const open = line.match(/^\s*<!--\s*diagram\s+([\w-]+)(\s+hand-drawn)?\s*$/);
    if (open) {
      // The image is the last non-empty line before the comment.
      let j = i - 1;
      while (j >= 0 && lines[j].trim() === '') j--;
      const image = j >= 0 ? lines[j].match(/^\s*!\[([^\]]*)\]\(([^)\s]+)\)\s*$/) : null;
      comment = {
        id: open[1],
        handDrawn: Boolean(open[2]),
        title: image ? image[1] : '',
        image: image ? image[2] : null,
        desc: image ? plainText(paragraphBefore(j)) : '',
        line: lineNo,
      };
      inComment = true;
      continue;
    }
    if (/^\s*<!--/.test(line)) {
      if (!line.includes('-->')) {
        inComment = true;
        comment = null;
      }
      continue;
    }

    for (const m of line.matchAll(/!?\[[^\]]*\]\(([^)\s]+)(?:\s+"[^"]*")?\)/g)) {
      links.push({ target: m[1], line: lineNo });
    }
    const ref = line.match(/^\s*\[[^\]]+\]:\s*(\S+)/);
    if (ref) links.push({ target: ref[1], line: lineNo });

    const isTable = /^\s*\|/.test(line);
    // A line that holds only an image or a link (a list item's too) cannot
    // be broken.
    const isLinkOnly = /^\s*(?:[-*]\s+|\d+\.\s+)?!?\[[^\]]*\]\([^)]*\)[.,;:]?\s*$/.test(line);
    if (!isTable && !isLinkOnly && [...line].length > maxLineLength) {
      longLines.push({ line: lineNo, length: [...line].length });
    }
  }
  return { diagrams, fences, links, longLines };
}

/** Whether [target] is a link the check resolves (relative, not a web
 *  address, a mail address or an anchor in the same document). */
export function isRelativeLink(target) {
  return !/^[a-z][a-z0-9+.-]*:/i.test(target) && !target.startsWith('#');
}

/** Where the exported files of diagram [id] of document [file] go:
 *  `<doc dir>/images/diagrams/<document>/<id>.svg|png`. */
export function exportPaths(file, id) {
  const dir = join(dirname(file), 'images', 'diagrams', basename(file, '.md'));
  return { svg: join(dir, `${id}.svg`), png: join(dir, `${id}.png`) };
}

/** The `data-tsm-source` hash an exported SVG carries, or null. */
export function exportedHash(svgText) {
  const m = svgText.match(/data-tsm-source="([0-9a-f]+)"/);
  return m ? m[1] : null;
}

/** Mermaid's SVG [svg] post-processed into the website style: the panel
 *  behind it, the font stack on the root, `role`, `aria-label`, `<title>`,
 *  `<desc>` and the source's hash. */
export function postProcess(svg, { title, desc, hash }) {
  const vb = svg.match(/viewBox="([-\d.]+)\s+([-\d.]+)\s+([-\d.]+)\s+([-\d.]+)"/);
  const panel = vb
    ? `<rect class="tsm-panel" x="${vb[1]}" y="${vb[2]}" width="${vb[3]}" height="${vb[4]}" rx="22" fill="${palette.panel}"/>`
    : '';
  const out = svg.replace(/<svg\b([^>]*)>/, (_, attrs) => {
    const cleaned = attrs
      .replace(/\s(role|aria-label|aria-roledescription|data-tsm-source)="[^"]*"/g, '')
      .replace(/\sstyle="[^"]*"/, '');
    return (
      `<svg${cleaned} role="img" aria-label="${escapeXml(title)}" ` +
      `font-family="${escapeXml(fontFamily)}" data-tsm-source="${hash}">` +
      `<title>${escapeXml(title)}</title><desc>${escapeXml(desc)}</desc>${panel}`
    );
  });
  return out;
}

/** Every Markdown file the tools read: the `.md` files under each root
 *  folder (recursively) and each root that is a file. A folder `article`
 *  is left out: it holds the overview's Medium export, generated and held
 *  current by `export_article.mjs --check`, its lines as Medium takes them. */
export function markdownFiles(roots, { readdir, statIsDir }) {
  const out = [];
  const walk = (dir) => {
    for (const name of readdir(dir).sort()) {
      const path = join(dir, name);
      if (name === 'node_modules' || name === 'article' || name.startsWith('.')) continue;
      if (statIsDir(path)) walk(path);
      else if (name.endsWith('.md')) out.push(path);
    }
  };
  for (const root of roots) {
    const path = resolve(root);
    if (statIsDir(path)) walk(path);
    else out.push(path);
  }
  return out;
}

/** The problems of document [file] the check finds without rendering: its
 *  long lines, its relative links that resolve to nothing, its diagrams
 *  without a source, an image or a title, and its exported files missing or
 *  stale. */
export function staticProblems(file, parsed) {
  const problems = [];
  const at = (line) => `${file}:${line}`;
  for (const l of parsed.longLines) {
    problems.push(`${at(l.line)}: line of ${l.length} characters (at most ${maxLineLength})`);
  }
  for (const link of parsed.links) {
    if (!isRelativeLink(link.target)) continue;
    const path = decodeURI(link.target.split('#')[0]);
    if (path === '') continue;
    if (!existsSync(resolve(dirname(file), path))) {
      problems.push(`${at(link.line)}: link to ${link.target}, which does not exist`);
    }
  }
  for (const d of parsed.diagrams) {
    if (d.missingSource) {
      problems.push(`${at(d.line)}: diagram ${d.id} has no mermaid fence in its comment`);
      continue;
    }
    if (d.rawArrowLine) {
      problems.push(
        `${at(d.rawArrowLine)}: diagram ${d.id}'s source holds "-->", which ends ` +
          'its comment on GitHub: write every ">" of the source as "&gt;"',
      );
    }
    if (!d.image || !d.title) {
      problems.push(`${at(d.line)}: diagram ${d.id} is not right after its image ![title](...)`);
      continue;
    }
    const { svg, png } = exportPaths(file, d.id);
    if (resolve(dirname(file), d.image) !== svg) {
      problems.push(`${at(d.line)}: diagram ${d.id}'s image is not ${svg}`);
    }
    if (!existsSync(svg) || !existsSync(png)) {
      problems.push(`${at(d.line)}: diagram ${d.id} is not exported: run tool/render_diagrams.mjs`);
      continue;
    }
    if (exportedHash(readFileSync(svg, 'utf8')) !== sourceHash(d.source)) {
      problems.push(
        `${at(d.line)}: diagram ${d.id}'s SVG is older than its source: ` +
          (d.handDrawn
            ? 'redraw it and set its data-tsm-source (render_diagrams.mjs --hash)'
            : 'run tool/render_diagrams.mjs'),
      );
    }
  }
  return problems;
}
