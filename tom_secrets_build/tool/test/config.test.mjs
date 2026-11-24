// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

// The configuration reference's completeness check: the environment
// variables and setting keys read in every language are found, tests and
// fixtures are not read, and a name missing from the reference is reported.
// Demo sources in a temporary folder.

import { strict as assert } from 'node:assert';
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { after, describe, test } from 'node:test';

import {
  configurationNames,
  environmentNamesIn,
  inSpans,
  missingFromReference,
  preferenceKeysIn,
  tsmFieldNamesIn,
} from '../config_lib.mjs';

describe('environment variables', () => {
  test('every language\'s lookup is found', () => {
    const sources = [
      "final d = Platform.environment['TSM_DATA_DIR'];",
      "final h = env['HOME'];",
      'const s = process.env.TSM_SERVICE;',
      'x = os.environ.get("TSM_ONE")',
      'y := os.Getenv("TSM_TWO")',
      'let z = std::env::var("TSM_THREE");',
      'String w = System.getenv("TSM_FOUR");',
      'const char *v = getenv("TSM_FIVE");',
      "final variable = os == 'macos' ? 'TMPDIR' : 'XDG_RUNTIME_DIR';",
      'variable = "TMPDIR" if system == "macos" else "XDG_RUNTIME_DIR"',
      'DEVELOPMENT_TEAM = "$(TSM_TEAM_ID)";',
      'echo "${TSM_SIX}" $TSM_SEVEN %TSM_EIGHT% $env:TSM_NINE',
    ];
    const names = environmentNamesIn(sources.join('\n'));
    for (const name of [
      'TSM_DATA_DIR', 'HOME', 'TSM_SERVICE', 'TSM_ONE', 'TSM_TWO',
      'TSM_THREE', 'TSM_FOUR', 'TSM_FIVE', 'TMPDIR', 'XDG_RUNTIME_DIR',
      'TSM_TEAM_ID', 'TSM_SIX', 'TSM_SEVEN', 'TSM_EIGHT', 'TSM_NINE',
    ]) {
      assert.ok(names.has(name), `${name} not found`);
    }
  });

  test('a C macro or a Python string that is no variable is not taken', () => {
    const names = environmentNamesIn(
      [
        'return TSM_OK;',
        "status = 'OK' if passed else 'FAILED'",
        'if (kind == TSM_ERR_LOCKED) {}',
      ].join('\n'),
    );
    assert.deepEqual([...names], []);
  });
});

describe('fields and setting keys', () => {
  test('quoted tsm.* names, interpolated ones up to the interpolation', () => {
    const names = tsmFieldNamesIn(
      "const _k = KdbxKey('tsm.urlMatch');\nfinal h = 'tsm.key-file.$id';",
    );
    assert.deepEqual([...names].sort(), ['tsm.key-file.', 'tsm.urlMatch']);
  });

  test('preference keys are the dotted static consts', () => {
    const keys = preferenceKeysIn(
      "static const view = 'view.layout';\nstatic const channel = 'tom_secrets_desktop/session';",
    );
    assert.deepEqual([...keys], ['view.layout']);
  });

  test('a name stands in a code span alone or as a part', () => {
    const spans = ['tsm.key-file.<id>', 'refreshMinutes', 'TSM_DATA_DIR=/srv'];
    assert.ok(inSpans('tsm.key-file.', spans));
    assert.ok(inSpans('refreshMinutes', spans));
    assert.ok(inSpans('TSM_DATA_DIR', spans));
    assert.ok(!inSpans('refresh', spans));
    assert.ok(!inSpans('TSM_DATA', spans));
  });
});

describe('the check over a tree', () => {
  const dir = mkdtempSync(join(tmpdir(), 'tsm-config-'));
  after(() => rmSync(dir, { recursive: true, force: true }));
  const write = (path, text) => {
    const file = join(dir, path);
    mkdirSync(dirname(file), { recursive: true });
    writeFileSync(file, text);
  };

  test('code is read, tests and fixtures are not; missing names reported', () => {
    write('pkg/lib/src/a.dart', "final x = Platform.environment['TSM_A'];\nconst k = 'tsm.alpha';");
    write('pkg/test/a_test.dart', "final y = Platform.environment['TSM_TEST_ONLY'];");
    write('pkg/test/fixtures/f.dart', "final z = Platform.environment['TSM_FIXTURE'];");
    write('tom_secrets_ui/lib/src/prefs.dart', "static const view = 'view.layout';");
    write(
      'tom_secrets_core/lib/src/device_settings.dart',
      "Map<String, Object?> toJson() => {\n    'refreshMinutes': refreshMinutes,\n  };",
    );
    const names = configurationNames([dir]);
    assert.deepEqual([...names.environment.keys()], ['TSM_A']);
    assert.deepEqual([...names.fields.keys()], ['tsm.alpha']);
    assert.deepEqual([...names.settings.keys()], ['refreshMinutes']);
    assert.deepEqual([...names.preferences.keys()], ['view.layout']);

    const reference = '`TSM_A`, `tsm.alpha` and `view.layout` but not the setting.';
    assert.deepEqual(
      missingFromReference(names, reference).map((m) => `${m.kind} ${m.name}`),
      ['settings refreshMinutes'],
    );
    assert.deepEqual(
      missingFromReference(names, `${reference} \`refreshMinutes\``),
      [],
    );
  });
});
