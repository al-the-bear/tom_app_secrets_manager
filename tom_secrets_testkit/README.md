# tom_secrets_testkit

> Part of the Tom Secrets Manager by Peter Nicolai Alexis Kyaw, BSD-3-Clause.

The Tom Secrets Manager's own test fixtures that more than one package's
suite needs. A dev dependency only: nothing shipped depends on it.

## Overview

Every suite of the product builds its fixtures in a scratch folder inside the
package it runs in (its gitignored `ztmp/test/`), never in the system temp
directory. This package holds that folder and the helper that fills it. It
is pure Dart (no Flutter), so a Dart and a Flutter suite use it alike.

## Getting it

The package is not published (`publish_to: none`); a package of this
repository takes it by path, as a dev dependency:

```yaml
dev_dependencies:
  tom_secrets_testkit:
    path: ../tom_secrets_testkit
```

It needs Dart 3.10 or later.

## What it holds

| API | What it is |
| --- | --- |
| `secretsScratchDir(name, {packageDir})` | a fresh, empty `ztmp/test/<name>` under the package the suite runs in (or `packageDir`); a folder left by an earlier run is replaced; a name that is empty, absolute or leaves `ztmp/test` is refused (`ArgumentError`) |
| `secretsWriteFile(root, relative, content)` | writes a fixture file under `root`, creating its folders, and returns it |

## Usage

```dart
import 'package:tom_secrets_testkit/tom_secrets_testkit.dart';

void main() {
  final root = secretsScratchDir('my_suite');
  final file = secretsWriteFile(root, 'vault/notes.txt', 'demo');
  print(file.readAsStringSync()); // demo
}
```

## Limits

- Scratch folders only, so far. The vault factory, the fake GitHub remote and
  the fake service for the UI tests join the package with the packages that
  first need them; until then each lives in its suite's `test/support/`.
- Tests use demo data under demo keys only; real secrets never enter a
  fixture.

## Further documentation

- [`tom_secrets_build`](../tom_secrets_build/README.md): the CI that runs
  every suite.

## Status

Version 0.1.0. Its own suite (`dart test`) checks that a scratch folder is
fresh, stays inside `ztmp/test` and that files are written with their
folders.

## Licence

BSD-3-Clause ([`LICENSE`](LICENSE)).
