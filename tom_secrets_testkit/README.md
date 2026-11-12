# Tom Secrets Testkit

The Tom Secrets Manager's own test fixtures that more than one package's
suite needs. A dev dependency only: nothing shipped depends on it.

## What it holds

| API | What it is |
| --- | --- |
| `secretsScratchDir(name)` | a fresh, empty `ztmp/test/<name>` under the package the suite runs in — never the system temp directory |
| `secretsWriteFile(root, relative, content)` | writes a fixture file, creating its folders |

The vault factory, the fake GitHub remote and the fake service for the UI
tests join it with the packages that first need them. Tests use demo data
under demo keys only; real secrets never enter a fixture.

## Usage

```yaml
dev_dependencies:
  tom_secrets_testkit:
    path: ../tom_secrets_testkit
```

```dart
import 'package:tom_secrets_testkit/tom_secrets_testkit.dart';

final root = secretsScratchDir('my_suite');
secretsWriteFile(root, 'vault/notes.txt', 'demo');
```

## Licence

BSD-3-Clause, see [`LICENSE`](LICENSE).
