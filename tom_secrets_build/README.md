# Tom Secrets Build

The manually driven CI of the Tom Secrets Manager. It analyzes and tests
every package of the product's three repositories — `app_secrets_manager`,
`tom_ai/secrets_manager` and `tom_ai/secrets_clients` — and runs the
licence-boundary check, strictly one step after another, keeping every log.

**A person starts it, from the repository.** Nothing schedules it: no launchd
agent, crontab, systemd timer, git hook or GitHub workflow (Actions is
switched off for the product's repositories).

## Running it

```bash
./ci.sh :all          # macOS, Linux: every stage, in order, past any red
./ci.sh :licences     # one stage; several may be named
./ci.sh --help        # the stages and options
```

On Windows, `.\ci.ps1 :all` from PowerShell or `ci.cmd :all` from cmd.exe.
The scripts take the Dart of the Flutter SDK (`FLUTTER_ROOT`, else `flutter`
on `PATH`, else `dart` on `PATH`) and run `pub get` here when the pubspec is
newer than the resolution.

The last line of output is the one summary line (`CI GREEN …` or
`CI RED …`, naming every red step and its log); the exit code is non-zero when
any step is red. The logs are in `testlog/<timestamp>/`, one per package and
step, plus `summary.txt`. Child processes run under the workspace flutter
lock, so two sessions never run flutter at once.

## Stages

| Stage | What it does |
| --- | --- |
| `:analyze` | `pub get` and `analyze` (infos fatal for Dart packages) in every package |
| `:test` | every package's suite, one full log per package; a package without `*_test.dart` is reported skipped |
| `:licences` | `pub get` in every package, then the licence-boundary check (`test/licence_boundary_test.dart`, tag `licence-boundary`); every non-Dart dependency manifest (`package.json`, `Cargo.toml`, `go.mod`, `pom.xml`, `pyproject.toml`, `setup.py`) is red until a closure check reads it, except a `go.mod` that requires nothing (its closure is the Go standard library, BSD-3), which the boundary check lists as checked |
| `:all` | the three stages above, in that order |

The packages are found, never listed: every directory with a `pubspec.yaml`
up to four levels below a repository root, leaving out `example/`, `test/`,
build output, scratch, `node_modules/` and the Flutter platform folders. A
repository that is not checked out is a red step of every stage. The build
stages of the desktop app join when `tom_secrets_app` exists.

## The licence-boundary check

For every package, from what it resolves (`.dart_tool/package_config.json`)
and the `dependencies:` of every package it reaches (dev dependencies are not
linked):

- **No copyleft in a closure.** Every linked package carries a permissive
  licence (BSD, MIT, Apache-2.0, ISC, zlib). A GPL family, an unrecognised
  licence or a missing `LICENSE` is red. The closure walk and the
  classification are `tom_test_support`'s `licence_audit.dart`.
- **KDBX through one gate.** Only `tom_secrets_core` declares
  `tom_kdbx_store`; no package declares a KDBX library itself (`tom_kpasslib`,
  `kpasslib`, `tom_kdbx`, `kdbx`); the packages of `tom_ai/secrets_clients`,
  `tom_secrets_relay` and this package link neither the store nor the core.

An exception is named in `secretsLicenceExceptions`, by package, with its
reason. The check prints each one on every run and turns red when one is no
longer needed. The one in force: this package links `ini` (LGPL-3.0) through
`tom_build_base` → `dcli`, tolerated because the CI is never distributed.
It goes when `tom_build_base` takes the workspace fork of `dcli` without `ini`
(webwork `kpass4`); the quest's todo `tsm_a_lic2` then removes the exception.

## Licence

BSD-3-Clause, see [`LICENSE`](LICENSE). Tooling: nothing shipped depends on
it.
