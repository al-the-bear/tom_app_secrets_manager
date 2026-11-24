// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

// Rendering through one headless browser (puppeteer, as
// @mermaid-js/mermaid-cli renders): a Mermaid source to SVG in the export's
// theme, and an SVG to PNG at twice its size.

import { renderMermaid } from '@mermaid-js/mermaid-cli';
import puppeteer from 'puppeteer';

import { mermaidConfig, withClassDefs } from './docs_lib.mjs';

/** Runs [work] with a browser, closed afterwards. */
export async function withBrowser(work) {
  const browser = await puppeteer.launch({ headless: true });
  try {
    return await work(browser);
  } finally {
    await browser.close();
  }
}

/** [source] rendered to SVG text in the export's theme; throws on a source
 *  Mermaid cannot render. */
export async function renderSvg(browser, source) {
  const { data } = await renderMermaid(browser, withClassDefs(source), 'svg', {
    backgroundColor: 'transparent',
    mermaidConfig,
    fontEmbed: false,
  });
  const svg = Buffer.from(data).toString('utf8');
  // Mermaid answers a syntax error with an SVG that says so.
  if (/class="error-icon"|Syntax error in text/.test(svg)) {
    throw new Error('Mermaid reports a syntax error');
  }
  return svg;
}

/** [svg] as PNG at twice its size, its rounded panel's corners transparent. */
export async function svgToPng(browser, svg) {
  const page = await browser.newPage();
  try {
    await page.setViewport({ width: 800, height: 600, deviceScaleFactor: 2 });
    await page.setContent(
      `<!doctype html><html><body style="margin:0;background:transparent">${svg}</body></html>`,
    );
    const element = await page.$('svg');
    return Buffer.from(await element.screenshot({ omitBackground: true }));
  } finally {
    await page.close();
  }
}
