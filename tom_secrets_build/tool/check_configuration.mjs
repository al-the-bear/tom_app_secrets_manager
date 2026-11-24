// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

// The configuration reference's completeness check (`ci.sh :docs`): every
// environment variable and setting key the code under the given roots reads
// must appear in the reference (config_lib.mjs says what counts).
//
//   node tool/check_configuration.mjs <configuration.md> <root> ...
//   node tool/check_configuration.mjs --list <root> ...
//
// Prints each missing name as `<kind> <name> (read in <file>)` and the
// count; exits 1 when one is missing, 2 on a usage error. `--list` prints
// every name found and where.

import { existsSync, readFileSync } from 'node:fs';
import { pathToFileURL } from 'node:url';

import { configurationNames, missingFromReference } from './config_lib.mjs';

async function main(args) {
  if (args[0] === '--list') {
    const names = configurationNames(args.slice(1));
    for (const [kind, map] of Object.entries(names)) {
      for (const [name, where] of [...map].sort()) {
        process.stdout.write(`${kind} ${name} ${where}\n`);
      }
    }
    return 0;
  }
  if (args.length < 2) {
    process.stderr.write(
      'usage: node tool/check_configuration.mjs <configuration.md> <root> ...\n' +
        '       node tool/check_configuration.mjs --list <root> ...\n',
    );
    return 2;
  }
  const [reference, ...roots] = args;
  for (const path of [reference, ...roots]) {
    if (!existsSync(path)) {
      process.stderr.write(`${path}: not found\n`);
      return 2;
    }
  }
  const names = configurationNames(roots);
  const missing = missingFromReference(names, readFileSync(reference, 'utf8'));
  for (const m of missing) {
    process.stdout.write(`${reference}: ${m.kind} ${m.name} (read in ${m.where}) is not in the reference\n`);
  }
  const total = Object.values(names).reduce((n, map) => n + map.size, 0);
  process.stdout.write(`${total} names read in the code, ${missing.length} missing from the reference\n`);
  return missing.length === 0 ? 0 : 1;
}

if (import.meta.url === pathToFileURL(process.argv[1]).href) {
  process.exitCode = await main(process.argv.slice(2));
}
