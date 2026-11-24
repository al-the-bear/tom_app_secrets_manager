// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

// The configuration reference's completeness check (`ci.sh :docs`): every
// environment variable and every setting key the code reads must appear in
// `tom_secrets_manager/doc/configuration.md`, so the reference cannot fall
// behind the code.
//
// What counts as read:
//
// - an **environment variable**: a name looked up in the environment in any
//   language of the three repositories (`Platform.environment['X']`,
//   `env['X']`, `process.env.X`, `os.environ.get("X")`, `os.Getenv("X")`,
//   `env::var("X")`, `System.getenv("X")`, `getenv("X")`, ...), every quoted
//   `TSM_*` or `XDG_*` name, and every `TSM_*` a script or build file
//   expands (`$TSM_X`, `${TSM_X}`, `$(TSM_X)`, `%TSM_X%`, `$env:TSM_X`);
// - a **setting key**: a key one of the configuration readers named in
//   [settingSources] reads (`bootstrap.yaml`, the device settings, the
//   shared configuration `tsm.config`, `relay.yaml`, the mobile app's
//   settings), and every quoted `tsm.*` name of the Dart libraries (entry,
//   group and metadata fields, keychain handles);
// - a **preference**: a key the apps keep in their preferences file, declared
//   as `static const x = 'group.key';` in `tom_secrets_ui` or
//   `tom_secrets_mobile`.
//
// Tests, fixtures, test vectors and generated or fetched folders are not
// read. A name appears in the reference when it stands in a code span
// (`` `name` ``) there, alone or as part of a longer span
// (`tsm.key-file.<id>` covers `tsm.key-file.`).

import { readdirSync, readFileSync, statSync } from 'node:fs';
import { join, relative, sep } from 'node:path';

/** Folders never read: tests, fixtures, vectors, build output, tools'
 *  caches and the conformance suite (a test harness). */
export const skippedFolders = new Set([
  '.dart_tool', '.git', '.build', 'build', 'dist', 'node_modules', 'target',
  'ztmp', 'testlog', 'test', 'tests', 'Tests', 'integration_test', 'fixtures',
  'vectors', 'example', 'Pods', 'release', 'conformance', 'third_party',
]);

/** Source files read for environment variables. */
const sourceExtensions = [
  '.dart', '.ts', '.mjs', '.js', '.py', '.go', '.rs', '.java', '.c', '.cpp',
  '.h', '.hpp', '.swift', '.kt', '.kts', '.gradle', '.sh', '.ps1', '.cmd',
  '.xcconfig', '.plist', '.entitlements', '.pbxproj',
];

/** A file that only tests read (named like a test). */
function isTestFile(name) {
  return /(_test\.\w+|\.test\.\w+|Tests?\.\w+)$/.test(name);
}

/** The environment lookups of every language, each capturing the name. */
const lookups = [
  /\benvironment\s*\[\s*['"]([A-Za-z_]\w*)['"]/g,
  /\benv\s*\[\s*['"]([A-Za-z_]\w*)['"]/g,
  /\bprocess\.env\.([A-Za-z_]\w*)/g,
  /\bprocess\.env\s*\[\s*['"]([A-Za-z_]\w*)['"]/g,
  /\bos\.environ(?:\.get)?\s*\(\s*['"]([A-Za-z_]\w*)['"]/g,
  /\bos\.environ\s*\[\s*['"]([A-Za-z_]\w*)['"]/g,
  /\bos\.(?:Getenv|LookupEnv)\(\s*"([A-Za-z_]\w*)"/g,
  /\benv::var(?:_os)?\(\s*"([A-Za-z_]\w*)"/g,
  /\bSystem\.getenv\(\s*"([A-Za-z_]\w*)"/g,
  /\bgetenv\(\s*"([A-Za-z_]\w*)"/g,
  /\benvironment\[\s*"([A-Za-z_]\w*)"\s*\]/g,
  /['"]((?:TSM|XDG)_[A-Z0-9_]+)['"]/g,
  /\$\{?((?:TSM)_[A-Z0-9_]+)/g,
  /\$\(((?:TSM)_[A-Z0-9_]+)\)/g,
  /%((?:TSM)_[A-Z0-9_]+)%/g,
  /\$env:((?:TSM)_[A-Z0-9_]+)/g,
];

/** The configuration readers whose keys are setting keys: a file relative
 *  to a repository root, and the patterns that capture its keys. */
export const settingSources = [
  {
    // bootstrap.yaml
    file: 'tom_secrets_service/lib/src/bootstrap.dart',
    patterns: [/doc\[\s*'([a-z_]+)'\s*\]/g, /\btext\(\s*'([a-z_]+)'\s*\)/g],
  },
  {
    // The device settings and the lock policies.
    file: 'tom_secrets_core/lib/src/device_settings.dart',
    patterns: [/^\s*'([A-Za-z]+)':\s/gm],
  },
  {
    // The shared configuration tsm.config.
    file: 'tom_secrets_core/lib/src/config.dart',
    patterns: [/\b(?:doc|raw|github)\[\s*'([a-z_]+)'\s*\]/g],
  },
  {
    // relay.yaml
    file: 'tom_secrets_relay/lib/src/config.dart',
    patterns: [
      /\bm\[\s*'([A-Za-z]+)'\s*\]/g,
      /\bsection\(\s*'([A-Za-z]+)'\s*\)/g,
      /\bstrings\(\s*'([A-Za-z]+)'\s*\)/g,
      /\bdos\[\s*'([A-Za-z]+)'\s*\]/g,
      /\bnumber\(\s*\w+,\s*'[\w.]*',\s*'([A-Za-z]+)'/g,
      /\bnumber\(\s*\w+,\s*'[\w.]*',\s*\n\s*'([A-Za-z]+)'/g,
    ],
  },
];

/** This check's own files, whose comments name example variables. */
const ownFiles = new Set(['config_lib.mjs', 'check_configuration.mjs']);

/** Every file under [dir] the check reads, recursively. */
export function sourceFiles(dir) {
  const out = [];
  const walk = (d) => {
    let names;
    try {
      names = readdirSync(d);
    } catch {
      return;
    }
    for (const name of names.sort()) {
      const path = join(d, name);
      let isDir;
      try {
        isDir = statSync(path).isDirectory();
      } catch {
        continue;
      }
      if (isDir) {
        if (!skippedFolders.has(name) && !name.startsWith('.')) walk(path);
      } else if (!isTestFile(name) && !ownFiles.has(name) && (sourceExtensions.some((e) => name.endsWith(e)) || name === 'Dockerfile')) {
        out.push(path);
      }
    }
  };
  walk(dir);
  return out;
}

/** A variable chosen by the OS (`os == 'macos' ? 'TMPDIR' : 'XDG_...'`,
 *  Python's `"TMPDIR" if ... else "XDG_..."`, Go's `variable := "..."`):
 *  counted only on a line about the environment, since the same shapes
 *  choose other capitalised strings too. */
const choices = [
  /\?\s*['"]([A-Z][A-Z0-9_]+)['"]\s*:\s*['"][A-Z][A-Z0-9_]+['"]/g,
  /\?\s*['"][A-Z][A-Z0-9_]+['"]\s*:\s*['"]([A-Z][A-Z0-9_]+)['"]/g,
  /['"]([A-Z][A-Z0-9_]+)['"]\s+if\b[^\n]*\belse\s+['"][A-Z][A-Z0-9_]+['"]/g,
  /\bvariable\s*:?=\s*['"]([A-Z][A-Z0-9_]+)['"]/g,
];

/** The environment variables [text] reads. */
export function environmentNamesIn(text) {
  const names = new Set();
  for (const pattern of lookups) {
    for (const m of text.matchAll(pattern)) names.add(m[1]);
  }
  for (const line of text.split('\n')) {
    if (!/variable|getenv|environ/i.test(line)) continue;
    for (const pattern of choices) {
      for (const m of line.matchAll(pattern)) names.add(m[1]);
    }
  }
  return names;
}

/** The quoted `tsm.*` names of a Dart source [text]; a name built by
 *  interpolation (`'tsm.key-file.$id'`) counts up to the interpolation. */
export function tsmFieldNamesIn(text) {
  const names = new Set();
  for (const m of text.matchAll(/['"](tsm\.[A-Za-z0-9_.-]*[A-Za-z0-9_.-])(?:['"]|\$)/g)) {
    names.add(m[1]);
  }
  return names;
}

/** The packages whose `static const` dotted names are preference keys. */
const preferencePackages = ['tom_secrets_ui/lib/', 'tom_secrets_mobile/lib/'];

/** The preference keys a Dart source [text] declares. */
export function preferenceKeysIn(text) {
  const keys = new Set();
  for (const m of text.matchAll(/static const \w+\s*=\s*'([a-z][A-Za-z]*\.[a-z][A-Za-z]*)';/g)) {
    keys.add(m[1]);
  }
  return keys;
}

/** The setting keys [text] reads, by [patterns]. */
export function settingKeysIn(text, patterns) {
  const keys = new Set();
  for (const pattern of patterns) {
    for (const m of text.matchAll(pattern)) keys.add(m[1]);
  }
  return keys;
}

/** Every name the code under [roots] reads: `{environment, settings,
 *  fields, preferences}`, each a Map from the name to the first file reading it
 *  (relative to its root). */
export function configurationNames(roots) {
  const environment = new Map();
  const settings = new Map();
  const fields = new Map();
  const preferences = new Map();
  const note = (map, name, where) => {
    if (!map.has(name)) map.set(name, where);
  };
  for (const root of roots) {
    for (const file of sourceFiles(root)) {
      const text = readFileSync(file, 'utf8');
      const where = relative(root, file).split(sep).join('/');
      for (const name of environmentNamesIn(text)) note(environment, name, where);
      if (file.endsWith('.dart') && where.includes('/lib/')) {
        for (const name of tsmFieldNamesIn(text)) note(fields, name, where);
      }
      if (file.endsWith('.dart') && preferencePackages.some((p) => where.startsWith(p))) {
        for (const key of preferenceKeysIn(text)) note(preferences, key, where);
      }
      for (const source of settingSources) {
        if (where.endsWith(source.file)) {
          for (const key of settingKeysIn(text, source.patterns)) note(settings, key, where);
        }
      }
    }
  }
  return { environment, settings, fields, preferences };
}

/** The text of every code span of the Markdown [text]. */
export function codeSpans(text) {
  const spans = [];
  for (const m of text.matchAll(/`([^`\n]+)`/g)) spans.push(m[1]);
  return spans;
}

/** Whether [name] stands in one of [spans]: the whole span, or a part of it
 *  bounded by a character that cannot continue the name. */
export function inSpans(name, spans) {
  const escaped = name.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  const pattern = new RegExp(`(^|[^A-Za-z0-9_])${escaped}(?![A-Za-z0-9_])`);
  return spans.some((s) => pattern.test(s));
}

/** The names of [names] (as [configurationNames] answers) the reference
 *  [text] does not hold, each `{kind, name, where}`. */
export function missingFromReference(names, text) {
  const spans = codeSpans(text);
  const missing = [];
  for (const [kind, map] of Object.entries(names)) {
    for (const [name, where] of [...map].sort()) {
      if (!inSpans(name, spans)) missing.push({ kind, name, where });
    }
  }
  return missing;
}
